import '../action.dart';
import '../backend.dart';
import '../screen_recording.dart';
import '../xctest_runner.dart';
import 'ios_sim_backend.dart';

/// iOS input through glint's XCUITest runner; screenshots, recording and lock stay on the bridge ([sim]).
class XcTestBackend implements InteractionBackend {
  XcTestBackend({required this.runner, required this.sim});

  final XcTestRunner runner;
  final IosSimBackend sim;

  /// The app under test; XCUITest types only into the app that holds keyboard focus.
  String? bundleId;

  @override
  String get label => 'ios-xctest(${sim.udid.length > 8 ? sim.udid.substring(0, 8) : sim.udid})';

  @override
  BackendCapabilities get capabilities => sim.capabilities;

  ({double x, double y}) _logical(int x, int y) =>
      (x: x / sim.devicePixelRatio, y: y / sim.devicePixelRatio);

  Future<void> _call(String path, Map<String, Object?> body) async {
    try {
      await runner.call('POST', path, body: body);
    } on XcTestRunnerError catch (e) {
      throw BackendToolError(
          backend: label, command: 'runner POST $path', exitCode: 1, stderr: [e.message, e.detail].whereType<String>().join(': '));
    }
  }

  @override
  Future<void> tap({required int physicalX, required int physicalY}) {
    final p = _logical(physicalX, physicalY);
    return _call('/tap', {'x': p.x, 'y': p.y});
  }

  @override
  Future<void> tapSequence(List<({int x, int y})> points, {required int intervalMs}) =>
      tapEachInTurn(this, points, intervalMs);

  @override
  Future<void> longPress({required int physicalX, required int physicalY, required int durationMs}) {
    final p = _logical(physicalX, physicalY);
    return _call('/longpress', {'x': p.x, 'y': p.y, 'ms': durationMs});
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
    final a = _logical(physicalX1, physicalY1);
    final b = _logical(physicalX2, physicalY2);
    return _call('/swipe', {'x1': a.x, 'y1': a.y, 'x2': b.x, 'y2': b.y, 'holdMs': holdMs});
  }

  @override
  Future<void> typeText(String text, {int? keyDelayMs}) =>
      _call('/type', {'text': text, if (bundleId != null) 'app': bundleId});

  @override
  Future<void> pressKey(KeyName key, {int count = 1, Set<KeyModifier> modifiers = const {}}) => _call('/key', {
        'key': key.name,
        'count': count,
        'mods': [for (final m in modifiers) m.name],
        if (bundleId != null) 'app': bundleId,
      });

  @override
  Future<void> selectAll() => _call('/key', {
        'key': 'a',
        'mods': ['cmd'],
        if (bundleId != null) 'app': bundleId,
      });

  @override
  Future<void> pressHardwareButton(HardwareButton button) => button == HardwareButton.home
      ? _call('/button', {'name': 'home'})
      : sim.pressHardwareButton(button);

  @override
  Future<ScreenRecording> startRecording(String path) => sim.startRecording(path);

  @override
  Future<bool?> lockState() => sim.lockState();

  @override
  Future<ScreenshotResult> screenshot(String path) => sim.screenshot(path);
}
