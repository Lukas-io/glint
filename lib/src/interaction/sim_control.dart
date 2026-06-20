import 'dart:convert';
import 'dart:io';

import 'backend.dart';
import 'image_size.dart';

/// Read-only snapshot of a booted iOS simulator's state.
class SimStatus {
  const SimStatus({
    required this.udid,
    required this.name,
    required this.state,
    this.osVersion,
    this.deviceType,
    this.appearance,
    this.contentSize,
  });

  final String udid;
  final String name;
  final String state; // Booted | Shutdown | ...
  final String? osVersion; // "iOS 26.5"
  final String? deviceType; // "iPhone Air"
  final String? appearance; // light | dark
  final String? contentSize; // text-size category

  Map<String, Object?> toJson() => {
        'udid': udid,
        'name': name,
        'state': state,
        if (osVersion != null) 'osVersion': osVersion,
        if (deviceType != null) 'deviceType': deviceType,
        if (appearance != null) 'appearance': appearance,
        if (contentSize != null) 'contentSize': contentSize,
      };
}

/// Status + lightweight control of an iOS simulator over `xcrun simctl`.
/// Heavier control (location, biometrics, push, status-bar) is roadmapped.
class SimControl {
  const SimControl();

  /// Full status for [udid], or null if no such device exists.
  Future<SimStatus?> status(String udid) async {
    final target = udid.toUpperCase();
    final entry = await _deviceEntry(target);
    if (entry == null) return null;
    final (json, runtimeKey) = entry;
    return SimStatus(
      udid: (json['udid'] as String?) ?? udid,
      name: (json['name'] as String?) ?? 'iOS Simulator',
      state: (json['state'] as String?) ?? 'Unknown',
      osVersion: _osVersionFromRuntimeKey(runtimeKey),
      deviceType: _prettyDeviceType(json['deviceTypeIdentifier'] as String?),
      appearance: await _ui(target, 'appearance'),
      contentSize: await _ui(target, 'content_size'),
    );
  }

  /// Set the simulator appearance. [mode] is `light` or `dark`.
  Future<String?> setAppearance(String udid, String mode) =>
      _run(['ui', udid, 'appearance', mode]);

  /// Open a URL / deeplink on the simulator.
  Future<String?> openUrl(String udid, String url) =>
      _run(['openurl', udid, url]);

  /// Capture a PNG screenshot to a temp file (works headless). Returns the
  /// saved path + pixel size (the size doubles as the tap-ratio reference:
  /// `ratio = pixel / size`), or an error string.
  Future<ScreenshotResult> screenshot(String udid, String path) async {
    final err = await _run(['io', udid, 'screenshot', path]);
    if (err != null) return ScreenshotResult(error: err);
    final size = pngSize(path);
    return ScreenshotResult(path: path, width: size?.$1, height: size?.$2);
  }

  /// Grant / revoke / reset a privacy permission.
  /// [action] is grant | revoke | reset; [service] e.g. photos, camera,
  /// location, contacts; [bundleId] required for grant/revoke.
  Future<String?> privacy(
    String udid,
    String action,
    String service, {
    String? bundleId,
  }) =>
      _run([
        'privacy',
        udid,
        action,
        service,
        if (bundleId != null) bundleId,
      ]);

  // ── internals ────────────────────────────────────────────────────────────

  Future<(Map<String, Object?>, String)?> _deviceEntry(String udid) async {
    final ProcessResult res;
    try {
      res = await Process.run('xcrun', ['simctl', 'list', 'devices', '-j']);
    } on Object {
      return null;
    }
    if (res.exitCode != 0) return null;
    final Object? json;
    try {
      json = jsonDecode(res.stdout as String);
    } on Object {
      return null;
    }
    if (json is! Map) return null;
    final devices = json['devices'];
    if (devices is! Map) return null;
    for (final entry in devices.entries) {
      final list = entry.value;
      if (list is! List) continue;
      for (final d in list) {
        if (d is! Map) continue;
        if ((d['udid'] as String?)?.toUpperCase() == udid) {
          return (d.cast<String, Object?>(), entry.key as String);
        }
      }
    }
    return null;
  }

  Future<String?> _ui(String udid, String key) async {
    try {
      final res = await Process.run('xcrun', ['simctl', 'ui', udid, key]);
      if (res.exitCode != 0) return null;
      final out = (res.stdout as String).trim();
      return out.isEmpty ? null : out;
    } on Object {
      return null;
    }
  }

  /// Runs `xcrun simctl <args>`. Returns null on success, else an error line.
  Future<String?> _run(List<String> args) async {
    final ProcessResult res;
    try {
      res = await Process.run('xcrun', ['simctl', ...args]);
    } on Object catch (e) {
      return 'simctl ${args.first} failed: $e';
    }
    if (res.exitCode == 0) return null;
    final err = (res.stderr as String).trim();
    return err.isEmpty ? 'simctl ${args.first} exited ${res.exitCode}' : err;
  }

  static String? _prettyDeviceType(String? id) {
    if (id == null) return null;
    const marker = 'SimDeviceType.';
    final i = id.indexOf(marker);
    final tail = i >= 0 ? id.substring(i + marker.length) : id;
    return tail.replaceAll('-', ' ');
  }

  // "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5".
  static String? _osVersionFromRuntimeKey(String key) {
    final m = RegExp(r'SimRuntime\.([A-Za-z]+)-(\d+)-(\d+)').firstMatch(key);
    if (m == null) return null;
    return '${m.group(1)} ${m.group(2)}.${m.group(3)}';
  }
}
