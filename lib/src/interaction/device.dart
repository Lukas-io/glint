import 'backend.dart';
import 'backends/adb_backend.dart';
import 'backends/ios_sim_backend.dart';

/// One device glint can drive. [createBackend] hides the [AdbBackend] /
/// [IosSimBackend] choice; [devicePixelRatio] and [screenSize] give tools the
/// coordinate math without switching on the concrete type.
sealed class DeviceTarget {
  const DeviceTarget();

  DevicePlatform get platform;

  /// iOS UDID or Android serial.
  String get id;

  /// Scale from input coordinates to physical pixels. iOS uses the real DPR;
  /// Android backends take raw pixels, so 1.0.
  double get devicePixelRatio;

  /// Screen size for device-mode center anchoring, or null if unknown.
  ({double w, double h})? get screenSize;

  InteractionBackend createBackend();
}

enum DevicePlatform { android, ios }

class AndroidDevice extends DeviceTarget {
  const AndroidDevice({
    required this.serial,
    this.adbPath = 'adb',
    this.screenWidth,
    this.screenHeight,
  });

  /// adb `-s` serial, e.g. `emulator-5554`.
  final String serial;
  final String adbPath;

  /// Screen pixels, set in device mode (from a screenshot); null in Flutter mode.
  final double? screenWidth;
  final double? screenHeight;

  @override
  DevicePlatform get platform => DevicePlatform.android;

  @override
  String get id => serial;

  @override
  double get devicePixelRatio => 1.0;

  @override
  ({double w, double h})? get screenSize =>
      (screenWidth != null && screenHeight != null)
          ? (w: screenWidth!, h: screenHeight!)
          : null;

  @override
  InteractionBackend createBackend() =>
      AdbBackend(deviceSerial: serial, adbPath: adbPath);
}

class IosSimulator extends DeviceTarget {
  const IosSimulator({
    required this.udid,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    required this.bridgePath,
  });

  final String udid;

  /// Logical size in points (Flutter mode) or screenshot pixels (device mode).
  final double logicalWidth;
  final double logicalHeight;

  @override
  final double devicePixelRatio;

  /// Path to the compiled `glint-iossim` Swift binary.
  final String bridgePath;

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  String get id => udid;

  @override
  ({double w, double h})? get screenSize => (w: logicalWidth, h: logicalHeight);

  @override
  InteractionBackend createBackend() => IosSimBackend(
        udid: udid,
        deviceLogicalWidth: logicalWidth,
        deviceLogicalHeight: logicalHeight,
        devicePixelRatio: devicePixelRatio,
        binaryPath: bridgePath,
      );
}
