import '../../runtime/flutter_runtime.dart';
import '../action.dart';
import '../backend.dart';
import '../flutter_input.dart';
import '../input_route.dart';
import '../result.dart';
import '../screen_recording.dart';
import '../touch_log.dart';
import '../touch_path.dart';

/// Delivers input inside the Flutter app when it can (exact, fast), and hands everything else to [native]: system surfaces, the keyboard, native views, buttons.
class FlutterInputBackend extends InteractionBackend {
  FlutterInputBackend({required this.native, required this.devicePixelRatio, this.route = InputRoute.auto});

  final InteractionBackend native;
  final double devicePixelRatio;
  final InputRoute route;

  /// The app's VM, bound once attach connects; null in device mode.
  FlutterRuntime? runtime;

  /// Where every touch sent through here is noted, for drawing onto recordings.
  TouchLog? touchLog;

  /// Whether another window has focus over the app (a system dialog, Android's notification shade) without changing the app's lifecycle; checked before each in-app delivery.
  Future<bool> Function()? coveredBySystem;

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

  Future<void> _deliver(
      Future<FlutterInputMiss?> Function(FlutterInput) viaFlutter, Future<void> Function() viaNative) async {
    final clock = Stopwatch()..start();
    final rt = runtime;
    if (route == InputRoute.device || rt == null || !rt.isAttached) {
      await viaNative();
      _last = (path: InputPath.device, reason: null, ms: clock.elapsedMilliseconds);
      return;
    }
    final input = FlutterInput(rt);
    final covered = await coveredBySystem?.call() ?? false;
    final miss = covered ? FlutterInputMiss.systemSurface : await viaFlutter(input);
    if (miss == null) {
      _last = (path: InputPath.app, reason: null, ms: clock.elapsedMilliseconds);
      return;
    }
    final why = input.lastError == null ? '' : ': ${input.lastError}';
    switch (miss) {
      case FlutterInputMiss.partial:
        final p = input.lastPartial;
        throw BackendFailure(GlintErrorKind.inputPartial, '${miss.reason}$why', nextSteps: const [
          'call get_scene to see what landed, then send only the rest; nothing was retried, so nothing landed twice'
        ], data: {
          if (p != null) 'delivered': p.delivered,
          if (p != null) 'of': p.of
        });
      case FlutterInputMiss.evalFailed:
        throw BackendFailure(GlintErrorKind.backendToolError, '${miss.reason}$why', nextSteps: const [
          'call get_scene: if the app answers, retry once; it was not sent another way, so it did not land twice'
        ]);
      case _ when route == InputRoute.app:
        throw BackendFailure(GlintErrorKind.unsupportedBackendAction, 'the app could not take it: ${miss.reason}',
            nextSteps: const ['attach again with input:auto so real touches handle what the app cannot'],
            data: {'reason': miss.name});
      case _:
        await viaNative();
        _last = (path: InputPath.device, reason: miss, ms: clock.elapsedMilliseconds);
    }
  }

  ({double x, double y, int ms}) _logical(int x, int y, int ms) =>
      (x: x / devicePixelRatio, y: y / devicePixelRatio, ms: ms);

  @override
  Future<void> tap({required int physicalX, required int physicalY}) {
    touchLog?.add([
      [(x: physicalX, y: physicalY, ms: 0), (x: physicalX, y: physicalY, ms: 40)]
    ]);
    return _deliver(
      (f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, 40)]),
      () => native.tap(physicalX: physicalX, physicalY: physicalY),
    );
  }

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) {
    touchLog?.add([
      [(x: physicalX, y: physicalY, ms: 0), (x: physicalX, y: physicalY, ms: durationMs)]
    ]);
    return _deliver(
      (f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, durationMs)]),
      () => native.longPress(physicalX: physicalX, physicalY: physicalY, durationMs: durationMs),
    );
  }

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
    int holdMs = 0,
  }) {
    final path = dragPath(physicalX1, physicalY1, physicalX2, physicalY2, durationMs: durationMs, holdMs: holdMs);
    touchLog?.add([path]);
    return _deliver(
      (f) => f.touch([for (final p in path) _logical(p.x, p.y, p.ms)]),
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
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) =>
      tapEachInTurn(this, points, intervalMs);

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) => _deliver(
        (f) => f.type(text, gapMs: keyDelayMs ?? 0),
        () => native.typeText(text, keyDelayMs: keyDelayMs),
      );

  @override
  Future<void> pressKey(KeyName key, {int count = 1, Set<KeyModifier> modifiers = const {}}) => _deliver(
        (f) async => modifiers.isEmpty ? f.key(key.name, count: count) : FlutterInputMiss.unsupportedKey,
        () => native.pressKey(key, count: count, modifiers: modifiers),
      );

  @override
  Future<void> selectAll() => _deliver((f) => f.selectAll(), native.selectAll);

  /// Pinch through the app when allowed, else real fingers; with no multi-touch on the device the app path still serves it.
  @override
  Future<void> pinch(
      {required int physicalX, required int physicalY, required double scale, int durationMs = 400}) async {
    final from = 120 * devicePixelRatio;
    touchLog?.add(_pinchFingers(physicalX, physicalY, from, from * scale, durationMs));
    Future<FlutterInputMiss?> viaApp(FlutterInput f) => f.pinch(physicalX / devicePixelRatio,
        physicalY / devicePixelRatio, from / devicePixelRatio, from * scale / devicePixelRatio, durationMs);
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
    await _deliver(
        viaApp, () => native.pinch(physicalX: physicalX, physicalY: physicalY, scale: scale, durationMs: durationMs));
  }

  /// Two fingers on a horizontal line through ([cx], [cy]) going from [from] to [to] pixels apart, as the app path moves them.
  static List<List<TouchPoint>> _pinchFingers(int cx, int cy, double from, double to, int durationMs) {
    final steps = (durationMs / 16).ceil().clamp(2, 400);
    List<TouchPoint> finger(int side) => [
          for (var i = 0; i <= steps; i++)
            (
              x: (cx + side * (from + (to - from) * i / steps) / 2).round(),
              y: cy,
              ms: (durationMs * i / steps).round(),
            ),
        ];
    return [finger(-1), finger(1)];
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
