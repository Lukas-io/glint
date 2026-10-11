import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

import '../interaction/emulator_control.dart';
import 'geo.dart';

/// One position glint feeds a device; [speed] in m/s and [heading] in degrees from north, when known.
typedef Fix = ({LatLng at, double? speed, double? heading, double? altitude});

/// The device refused a location change; [detail] is its own message.
class LocationFailed implements Exception {
  LocationFailed(this.summary, this.detail);
  final String summary;
  final String detail;
}

/// What the device says about location: whether its location services are on and whether [app] has a live location request; null when the platform does not tell.
typedef LocationSignals = ({bool? servicesOn, bool? listening});

/// Feeds simulated positions to one device.
sealed class LocationBackend {
  String get label;

  String get id;

  Future<LocationSignals> signals(String? app) async => (servicesOn: null, listening: null);

  Future<void> set(Fix fix);

  /// Stops the simulation, so the device reports no simulated position; false when the platform keeps the last fix.
  Future<bool> clear();

  /// The quickest the device takes one fix after another.
  Duration get minInterval;

  /// Whether the device can travel a whole leg itself through [drive], reporting a real heading on the way.
  bool get drivesRoutes => false;

  Future<void> drive(List<LatLng> points, {required double speed, required Duration interval}) =>
      throw UnsupportedError('$label cannot travel a route by itself');

  static LocationBackend forDevice(String id, {required bool physical, String adbPath = 'adb'}) {
    if (id.startsWith('emulator-')) return AndroidEmulatorLocation(id, adbPath: adbPath);
    return physical ? IosDeviceLocation(id) : IosSimulatorLocation(id);
  }
}

Future<void> _run(String exe, List<String> args, String what) async {
  final ProcessResult r;
  try {
    r = await Process.run(exe, args).timeout(const Duration(seconds: 20));
  } on Object catch (e) {
    throw LocationFailed('could not run $exe for $what', '$e');
  }
  if (r.exitCode != 0) throw LocationFailed('the device refused $what', '${r.stderr}'.trim());
}

String _n(double v) => v.toStringAsFixed(6);

class IosSimulatorLocation extends LocationBackend {
  IosSimulatorLocation(this.udid);
  final String udid;

  @override
  String get id => udid;

  @override
  String get label => 'iOS simulator $udid';

  @override
  Duration get minInterval => const Duration(milliseconds: 500);

  @override
  Future<void> set(Fix fix) => _run('xcrun', ['simctl', 'location', udid, 'set', '${_n(fix.at.lat)},${_n(fix.at.lng)}'], 'the location');

  @override
  Future<bool> clear() async {
    await _run('xcrun', ['simctl', 'location', udid, 'clear'], 'clearing the location');
    return true;
  }

  @override
  bool get drivesRoutes => true;

  /// CoreSimulator interpolates the leg and gives the app a course, which `set` never does.
  @override
  Future<void> drive(List<LatLng> points, {required double speed, required Duration interval}) async {
    final Process process;
    try {
      process = await Process.start('xcrun', [
        'simctl', 'location', udid, 'start', '--speed=${speed.toStringAsFixed(2)}',
        '--interval=${(interval.inMilliseconds / 1000).toStringAsFixed(1)}', '-',
      ]);
    } on Object catch (e) {
      throw LocationFailed('could not run xcrun for the route', '$e');
    }
    process.stdin.writeln(points.map((p) => '${_n(p.lat)},${_n(p.lng)}').join('\n'));
    await process.stdin.close();
    final err = await process.stderr.transform(const SystemEncoding().decoder).join();
    final code = await process.exitCode.timeout(const Duration(seconds: 20), onTimeout: () {
      process.kill();
      return -1;
    });
    if (code != 0) throw LocationFailed('the simulator refused the route', err.trim());
  }
}

class IosDeviceLocation extends LocationBackend {
  IosDeviceLocation(this.udid);
  final String udid;

  @override
  String get id => udid;

  @override
  String get label => 'iPhone $udid';

  @override
  Duration get minInterval => const Duration(seconds: 2);

  @override
  Future<void> set(Fix fix) => _run('xcrun', [
        'devicectl', 'device', 'simulate', 'location', 'coordinate', '--device', udid,
        '--latitude', _n(fix.at.lat), '--longitude', _n(fix.at.lng), '-q',
      ], 'the location');

  @override
  Future<bool> clear() async {
    await _run('xcrun', ['devicectl', 'device', 'simulate', 'location', 'clear', '--device', udid, '-q'], 'clearing the location');
    return true;
  }
}

const _metersPerSecondPerKnot = 0.514444;

/// The emulator's gRPC `setGps`, which also carries speed, heading and altitude.
class AndroidEmulatorLocation extends LocationBackend {
  AndroidEmulatorLocation(this.serial, {this.adbPath = 'adb'});
  final String serial;
  final String adbPath;

  @override
  String get id => serial;

  @override
  String get label => 'Android emulator $serial';

  @override
  Duration get minInterval => const Duration(milliseconds: 200);

  @override
  Future<void> set(Fix fix) async {
    final endpoint = EmulatorEndpoint.find(serial);
    if (endpoint == null) throw LocationFailed('found no control endpoint for $serial', 'is the emulator running?');
    final control = EmulatorControl(endpoint);
    try {
      await control.setGps(gpsState(fix)).timeout(const Duration(seconds: 5));
    } on GrpcError catch (e) {
      throw LocationFailed('the emulator refused the location', '${e.message}');
    } on TimeoutException {
      throw LocationFailed('the emulator did not take the location', 'no answer in 5 s');
    } finally {
      await control.close();
    }
  }

  @override
  Future<LocationSignals> signals(String? app) async {
    Future<String?> shell(List<String> args) async {
      try {
        final r = await Process.run(adbPath, ['-s', serial, 'shell', ...args]).timeout(const Duration(seconds: 10));
        return r.exitCode == 0 ? '${r.stdout}' : null;
      } on Object {
        return null;
      }
    }

    final enabled = (await shell(['cmd', 'location', 'is-location-enabled']))?.trim();
    final servicesOn = enabled == 'true' ? true : (enabled == 'false' ? false : null);
    if (app == null) return (servicesOn: servicesOn, listening: null);
    final dump = await shell(['dumpsys', 'location']);
    return (servicesOn: servicesOn, listening: dump == null ? null : appRequestsLocation(dump, app));
  }

  /// True when [app] holds an active location request in a `dumpsys location` dump, directly or through Play services' fused provider.
  static bool appRequestsLocation(String dump, String app) {
    final providers = dump.indexOf('Location Providers:');
    final history = dump.indexOf('Historical Aggregate');
    final section = providers < 0 ? dump : dump.substring(providers, history > providers ? history : dump.length);
    return section.split('\n').any((l) => l.contains('Request[') && l.contains(app) && !l.contains('(inactive)'));
  }

  /// The emulator keeps its last fix; there is no "no location" state to go back to.
  @override
  Future<bool> clear() async => false;

  /// A `GpsState` message (speed in knots, as the emulator reads it) with passive updates off so the emulator's own location panel does not override it.
  static List<int> gpsState(Fix fix) {
    List<int> f64(int field, double v) => [(field << 3) | 1, ...(ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List()];
    return [
      ...f64(2, fix.at.lat),
      ...f64(3, fix.at.lng),
      if (fix.speed != null) ...f64(4, fix.speed! / _metersPerSecondPerKnot),
      if (fix.heading != null) ...f64(5, fix.heading!),
      if (fix.altitude != null) ...f64(6, fix.altitude!),
      0x38, 8,
    ];
  }
}
