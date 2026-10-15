import '../../runtime/flutter_runtime.dart';
import '../action.dart';
import '../backend.dart';
import '../flutter_input.dart';
import '../screen_recording.dart';

/// How a [FlutterInputBackend] picks its path: Flutter first with the platform for the rest, the platform only, or Flutter only.
enum InputRoute { auto, native, flutter }

/// Delivers input inside the Flutter app when it can (exact, fast), and hands everything else to [native]: system surfaces, the keyboard, native views, buttons.
class FlutterInputBackend extends InteractionBackend {
  FlutterInputBackend({required this.native, required this.devicePixelRatio, this.route = InputRoute.auto});

  final InteractionBackend native;
  final double devicePixelRatio;
  final InputRoute route;

  /// The app's VM, bound once attach connects; null in device mode.
  FlutterRuntime? runtime;

  String? _lastRoute;

  @override
  String get label => native.label;

  @override
  String? takeRoute() {
    final r = _lastRoute;
    _lastRoute = null;
    return r;
  }

  @override
  BackendCapabilities get capabilities {
    final n = native.capabilities;
    final flutter = route != InputRoute.native && runtime != null;
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

  Future<void> _deliver(String what, Future<FlutterInputMiss?> Function(FlutterInput) viaFlutter, Future<void> Function() viaNative) async {
    final rt = runtime;
    if (route == InputRoute.native || rt == null || !rt.isAttached) {
      _lastRoute = route == InputRoute.native ? 'device input' : null;
      return viaNative();
    }
    final input = FlutterInput(rt);
    final miss = await viaFlutter(input);
    if (miss == null) {
      _lastRoute = 'flutter';
      return;
    }
    if (miss == FlutterInputMiss.evalFailed || miss == FlutterInputMiss.partial) {
      throw UnsupportedBackendAction(label, '$what: ${miss.reason}${input.lastError == null ? '' : ': ${input.lastError}'}',
          nextSteps: const ['call get_scene to see what landed, then send only the rest; it is not retried, so nothing lands twice']);
    }
    if (route == InputRoute.flutter) {
      throw UnsupportedBackendAction(label, '$what: Flutter could not take it, ${miss.reason}',
          nextSteps: const ['attach again with iosInput:auto to let device input handle what Flutter cannot']);
    }
    await viaNative();
    _lastRoute = 'device input (${miss.reason})';
  }

  ({double x, double y, int ms}) _logical(int x, int y, int ms) => (x: x / devicePixelRatio, y: y / devicePixelRatio, ms: ms);

  @override
  Future<void> tap({required int physicalX, required int physicalY}) => _deliver(
        'tap',
        (f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, 40)]),
        () => native.tap(physicalX: physicalX, physicalY: physicalY),
      );

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) => _deliver(
        'long press',
        (f) => f.touch([_logical(physicalX, physicalY, 0), _logical(physicalX, physicalY, durationMs)]),
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
    return _deliver(
      'swipe',
      (f) => f.touch([
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
  Future<void> typeText(String text, {int? keyDelayMs}) => _deliver(
        'type',
        (f) => f.type(text, gapMs: keyDelayMs ?? 0),
        () => native.typeText(text, keyDelayMs: keyDelayMs),
      );

  @override
  Future<void> pressKey(KeyName key, {int count = 1, Set<KeyModifier> modifiers = const {}}) => _deliver(
        'key ${key.name}',
        (f) async => modifiers.isEmpty ? f.key(key.name, count: count) : FlutterInputMiss.unsupportedKey,
        () => native.pressKey(key, count: count, modifiers: modifiers),
      );

  @override
  Future<void> selectAll() => _deliver('select all', (f) => f.selectAll(), native.selectAll);

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
}
