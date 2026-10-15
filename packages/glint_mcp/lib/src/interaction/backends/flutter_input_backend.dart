import '../../runtime/flutter_runtime.dart';
import '../action.dart';
import '../backend.dart';
import '../flutter_input.dart';
import '../input_route.dart';
import '../result.dart';
import '../screen_recording.dart';

/// Delivers input inside the Flutter app when it can (exact, fast), and hands everything else to [native]: system surfaces, the keyboard, native views, buttons.
class FlutterInputBackend extends InteractionBackend {
  FlutterInputBackend({required this.native, required this.devicePixelRatio, this.route = InputRoute.auto});

  final InteractionBackend native;
  final double devicePixelRatio;
  final InputRoute route;

  /// The app's VM, bound once attach connects; null in device mode.
  FlutterRuntime? runtime;

  InputReport? _last;

  @override
  String get label => native.label;

  @override
  InputReport? takeInput() {
    final r = _last;
    _last = null;
    return r;
  }

  @override
  BackendCapabilities get capabilities {
    final n = native.capabilities;
    final flutter = route != InputRoute.device && runtime != null;
    return BackendCapabilities(
      tap: n.tap || flutter,
      longPress: n.longPress || flutter,
      doubleTap: n.doubleTap || flutter,
      swipe: n.swipe || flutter,
      typeText: n.typeText || flutter,
      keys: n.keys || flutter,
      record: n.record,
      hardwareButtons: n.hardwareButtons,
    );
  }

  Future<void> _deliver(Future<FlutterInputMiss?> Function(FlutterInput) viaFlutter, Future<void> Function() viaNative) async {
    final clock = Stopwatch()..start();
    final rt = runtime;
    if (route == InputRoute.device || rt == null || !rt.isAttached) {
      await viaNative();
      _last = (path: InputPath.device, reason: null, ms: clock.elapsedMilliseconds);
      return;
    }
    final input = FlutterInput(rt);
    final miss = await viaFlutter(input);
    if (miss == null) {
      _last = (path: InputPath.app, reason: null, ms: clock.elapsedMilliseconds);
      return;
    }
    final why = input.lastError == null ? '' : ': ${input.lastError}';
    switch (miss) {
      case FlutterInputMiss.partial:
        final p = input.lastPartial;
        throw BackendFailure(GlintErrorKind.inputPartial, '${miss.reason}$why',
            nextSteps: const ['call get_scene to see what landed, then send only the rest; nothing was retried, so nothing landed twice'],
            data: {if (p != null) 'delivered': p.delivered, if (p != null) 'of': p.of});
      case FlutterInputMiss.evalFailed:
        throw BackendFailure(GlintErrorKind.backendToolError, '${miss.reason}$why',
            nextSteps: const ['call get_scene: if the app answers, retry once; it was not sent another way, so it did not land twice']);
      case _ when route == InputRoute.app:
        throw BackendFailure(GlintErrorKind.unsupportedBackendAction, 'the app could not take it: ${miss.reason}',
            nextSteps: const ['attach again with input:auto so real touches handle what the app cannot'],
            data: {'reason': miss.name});
      case _:
        await viaNative();
        _last = (path: InputPath.device, reason: miss, ms: clock.elapsedMilliseconds);
    }
  }

  ({double x, double y, int ms}) _logical(int x, int y, int ms) => (x: x / devicePixelRatio, y: y / devicePixelRatio, ms: ms);

  @override
  Future<void> tap({required int physicalX, required int physicalY}) => _deliver((f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, 40)]),
        () => native.tap(physicalX: physicalX, physicalY: physicalY),
      );

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) => _deliver((f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, durationMs)]),
        () => native.longPress(physicalX: physicalX, physicalY: physicalY, durationMs: durationMs),
      );

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
    int holdMs = 0,
  }) {
    final steps = (durationMs / 16).ceil().clamp(2, 400);
    return _deliver((f) => f.touch([
        _logical(physicalX1, physicalY1, 0),
        if (holdMs > 0) _logical(physicalX1, physicalY1, holdMs),
        for (var i = 1; i <= steps; i++)
          _logical(
            (physicalX1 + (physicalX2 - physicalX1) * i / steps).round(),
            (physicalY1 + (physicalY2 - physicalY1) * i / steps).round(),
            holdMs + (durationMs * i / steps).round(),
          ),
      ]),
      () => native.swipe(
          physicalX1: physicalX1,
          physicalY1: physicalY1,
          physicalX2: physicalX2,
          physicalY2: physicalY2,
          durationMs: durationMs,
          holdMs: holdMs),
    );
  }

  @override
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) => tapEachInTurn(this, points, intervalMs);

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) => _deliver((f) => f.type(text, gapMs: keyDelayMs ?? 0),
        () => native.typeText(text, keyDelayMs: keyDelayMs),
      );

  @override
  Future<void> pressKey(KeyName key, {int count = 1, Set<KeyModifier> modifiers = const {}}) => _deliver((f) async => modifiers.isEmpty ? f.key(key.name, count: count) : FlutterInputMiss.unsupportedKey,
        () => native.pressKey(key, count: count, modifiers: modifiers),
      );

  @override
  Future<void> selectAll() => _deliver((f) => f.selectAll(), native.selectAll);

  /// Pinch through the app when allowed, else real fingers; with no multi-touch on the device the app path still serves it.
  @override
  Future<void> pinch({required int physicalX, required int physicalY, required double scale, int durationMs = 400}) async {
    final from = 120 * devicePixelRatio;
    final viaApp = (FlutterInput f) =>
        f.pinch(physicalX / devicePixelRatio, physicalY / devicePixelRatio, from / devicePixelRatio, from * scale / devicePixelRatio, durationMs);
    if (route == InputRoute.device) {
      try {
        await native.pinch(physicalX: physicalX, physicalY: physicalY, scale: scale, durationMs: durationMs);
        _last = (path: InputPath.device, reason: null, ms: durationMs);
        return;
      } on UnsupportedBackendAction {
        if (runtime == null) rethrow;
      }
      final miss = await viaApp(FlutterInput(runtime!));
      if (miss != null) throw BackendFailure(GlintErrorKind.unsupportedBackendAction, 'pinch: ${miss.reason}');
      _last = (path: InputPath.app, reason: null, ms: durationMs);
      return;
    }
    await _deliver(viaApp, () => native.pinch(physicalX: physicalX, physicalY: physicalY, scale: scale, durationMs: durationMs));
  }

  @override
  Future<void> edgeSwipe(ScreenEdge edge) async {
    await native.edgeSwipe(edge);
    _last = (path: InputPath.device, reason: null, ms: 0);
  }

  @override
  Future<void> pressHardwareButton(HardwareButton button) => native.pressHardwareButton(button);

  @override
  Future<ScreenRecording> startRecording(String path) => native.startRecording(path);

  @override
  Future<bool?> lockState() => native.lockState();

  @override
  Future<ScreenshotResult> screenshot(String path) => native.screenshot(path);

  @override
  Future<void> close() => native.close();

  @override
  Future<void> warm() => native.warm();
}
