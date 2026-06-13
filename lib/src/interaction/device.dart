import 'backend.dart';
import 'backends/adb_backend.dart';
import 'backends/ios_sim_backend.dart';

/// One device glint can drive. Use [createBackend] to get an
/// [InteractionBackend] without choosing between [AdbBackend] /
/// [IosSimBackend] yourself.
sealed class DeviceTarget {
  const DeviceTarget();

  /// Platform tag — used in logs / MCP responses.
  DevicePlatform get platform;

  InteractionBackend createBackend();
}

enum DevicePlatform { android, ios }

class AndroidDevice extends DeviceTarget {
  const AndroidDevice({required this.serial, this.adbPath = 'adb'});

  /// adb `-s` serial. e.g. `emulator-5554` or a real-device id.
  final String serial;

  /// Path to the `adb` binary. Defaults to whatever's on PATH.
  final String adbPath;

  @override
  DevicePlatform get platform => DevicePlatform.android;

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

  /// Booted simulator UDID.
  final String udid;

  /// Logical device size in points (e.g. iPhone 17 Pro = 402×874).
  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;

  /// Path to the compiled `glint-iossim` Swift binary.
  final String bridgePath;

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  InteractionBackend createBackend() => IosSimBackend(
        udid: udid,
        deviceLogicalWidth: logicalWidth,
        deviceLogicalHeight: logicalHeight,
        devicePixelRatio: devicePixelRatio,
        binaryPath: bridgePath,
      );
}
