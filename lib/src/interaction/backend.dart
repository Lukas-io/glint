import 'action.dart';

/// Platform-native input layer. Speaks physical pixels; the Interactor
/// resolves symbolic targets before calling here.
abstract class InteractionBackend {
  BackendCapabilities get capabilities;
  String get label;

  Future<void> tap({required int physicalX, required int physicalY});

  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  });

  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  });

  Future<void> typeText(String text);

  Future<void> pressHardwareButton(HardwareButton button);

  /// Capture a PNG to [path] for device-mode perception; also the coordinate reference (ratio = pixel / size).
  Future<ScreenshotResult> screenshot(String path);
}

/// Outcome of [InteractionBackend.screenshot]: saved path + pixel size, or [error] on failure.
class ScreenshotResult {
  const ScreenshotResult({this.path, this.width, this.height, this.error});
  final String? path;
  final int? width;
  final int? height;
  final String? error;
}

class BackendCapabilities {
  const BackendCapabilities({
    this.tap = true,
    this.longPress = true,
    this.doubleTap = true,
    this.swipe = true,
    this.typeText = true,
    this.hardwareButtons = const <HardwareButton>{},
  });

  final bool tap;
  final bool longPress;
  final bool doubleTap;
  final bool swipe;
  final bool typeText;
  final Set<HardwareButton> hardwareButtons;
}

class UnsupportedBackendAction implements Exception {
  UnsupportedBackendAction(this.backend, this.detail);
  final String backend;
  final String detail;
  @override
  String toString() => 'UnsupportedBackendAction($backend): $detail';
}

class BackendToolError implements Exception {
  BackendToolError({
    required this.backend,
    required this.command,
    required this.exitCode,
    required this.stderr,
  });
  final String backend;
  final String command;
  final int exitCode;
  final String stderr;
  @override
  String toString() =>
      'BackendToolError($backend, $command, exit=$exitCode): $stderr';
}
