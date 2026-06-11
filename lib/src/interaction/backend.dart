import 'action.dart';

/// A platform-native input layer for one device.
///
/// Implementations: `AdbBackend` (Android emulator, `adb shell input`),
/// `IosSimBackend` (iOS Simulator, shells to `glint-iossim`).
///
/// Backends are *dumb on purpose* (§4): they accept already-resolved
/// physical-pixel coordinates and a typed [Action]. They do NOT know
/// about [SymbolicTarget] or Module B — the [Interactor] resolves
/// symbols first and hands the backend pure geometry.
///
/// Backends declare their [capabilities] so the [Interactor] can refuse
/// or warn before reaching them.
abstract class InteractionBackend {
  /// What this backend can do. Used by [Interactor] to refuse early.
  BackendCapabilities get capabilities;

  /// Short string for logs / errors. e.g. `"adb (emulator-5554)"`,
  /// `"ios-sim (E223E4B6...)"`.
  String get label;

  /// Single tap at physical-pixel `(x, y)`.
  Future<void> tap({required int physicalX, required int physicalY});

  /// Hold at `(x, y)` for [durationMs] then release.
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  });

  /// Straight-line drag from `(x1, y1)` to `(x2, y2)` over [durationMs].
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  });

  /// Send literal text to whatever field is focused. The backend handles
  /// keyboard layout / IME concerns — callers don't think about it.
  Future<void> typeText(String text);

  /// Press one of the hardware buttons. Backend throws
  /// [UnsupportedBackendAction] if it doesn't expose the button (e.g.
  /// iOS has no [HardwareButton.back] or [HardwareButton.appSwitcher]).
  Future<void> pressHardwareButton(HardwareButton button);
}

/// What a backend supports. Booleans because v1 surface is small.
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

  /// Subset of [HardwareButton] this backend can press.
  final Set<HardwareButton> hardwareButtons;
}

/// Thrown by a backend that's asked to perform an action it doesn't
/// support (e.g. Android-only `back` on iOS).
class UnsupportedBackendAction implements Exception {
  UnsupportedBackendAction(this.backend, this.detail);
  final String backend;
  final String detail;
  @override
  String toString() => 'UnsupportedBackendAction($backend): $detail';
}

/// Thrown by a backend when its underlying tool (`adb`, `glint-iossim`,
/// …) fails. Carries the tool's exit code and stderr verbatim so the
/// Interactor can put it in the result's `error` field unchanged.
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
