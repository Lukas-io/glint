import 'dart:convert';
import 'dart:io';

import 'device.dart';

/// A simulator / emulator that is currently booted and drivable.
class BootedDevice {
  const BootedDevice({
    required this.platform,
    required this.id,
    required this.name,
    this.osVersion,
  });

  /// ios → simulator UDID; android → adb serial.
  final DevicePlatform platform;
  final String id;
  final String name;

  /// e.g. "iOS 26.5". Null when unknown.
  final String? osVersion;

  Map<String, Object?> toJson() => {
        'platform': platform.name,
        'id': id,
        'name': name,
        if (osVersion != null) 'osVersion': osVersion,
      };
}

/// The device an app is actually running on, recovered from a VM service port.
class AppDeviceLink {
  const AppDeviceLink({required this.deviceId, this.appName});

  /// iOS simulator UDID or Android serial that hosts the app on this port.
  final String deviceId;

  /// App display name (iOS: from the `.app` bundle path). Null if unknown.
  final String? appName;
}

/// What [DeviceDiscovery.scan] found: running Flutter VM service URIs and
/// booted devices. The two lists are deliberately uncorrelated — a VM URI
/// on 127.0.0.1 carries no device identity, so `attach` resolves the pairing
/// later (one app + one device of the right platform = unambiguous; otherwise
/// the agent picks).
class DiscoveryResult {
  const DiscoveryResult({required this.vmUris, required this.devices});

  final List<Uri> vmUris;
  final List<BootedDevice> devices;

  List<BootedDevice> devicesFor(DevicePlatform p) =>
      devices.where((d) => d.platform == p).toList();
}

/// Finds running Flutter apps + booted devices so `attach` can auto-fill what
/// the agent didn't pass. Pure host inspection, no extra dependency: `ps` for
/// VM URIs, `xcrun simctl` for iOS sims, `adb devices` for Android.
class DeviceDiscovery {
  const DeviceDiscovery({this.adbPath = 'adb'});

  final String adbPath;

  Future<DiscoveryResult> scan() async {
    final vmUris = await _scanVmUris();
    final ios = await _bootedIosSims();
    final android = await _adbDevices();
    return DiscoveryResult(vmUris: vmUris, devices: [...ios, ...android]);
  }

  // ── running Flutter VM service URIs ──────────────────────────────────────
  // The canonical Dart VM service URI: http://127.0.0.1:PORT/TOKEN=/ . We scan
  // the full (untruncated) process args and keep only localhost matches found
  // on Dart/Flutter lines, so unrelated localhost URLs don't leak in.
  static final _vmUriPattern = RegExp(
    r'http://(?:127\.0\.0\.1|localhost):\d+/[A-Za-z0-9_=+\-/]*',
  );

  Future<List<Uri>> _scanVmUris() async {
    final ProcessResult res;
    try {
      res = await Process.run('ps', ['-Axww', '-o', 'args=']);
    } on Object {
      return const [];
    }
    if (res.exitCode != 0) return const [];

    final seen = <String>{};
    final uris = <Uri>[];
    for (final line in (res.stdout as String).split('\n')) {
      if (!line.contains('dart') &&
          !line.contains('flutter') &&
          !line.contains('vm-service') &&
          !line.contains('development-service')) {
        continue;
      }
      for (final m in _vmUriPattern.allMatches(line)) {
        final raw = m.group(0)!;
        if (seen.add(raw)) {
          final parsed = Uri.tryParse(raw);
          if (parsed != null) uris.add(parsed);
        }
      }
    }
    return uris;
  }

  // ── booted iOS simulators ────────────────────────────────────────────────
  Future<List<BootedDevice>> _bootedIosSims() async {
    final ProcessResult res;
    try {
      res = await Process.run(
        'xcrun',
        ['simctl', 'list', 'devices', 'booted', '-j'],
      );
    } on Object {
      return const [];
    }
    if (res.exitCode != 0) return const [];

    final Object? json;
    try {
      json = jsonDecode(res.stdout as String);
    } on Object {
      return const [];
    }
    if (json is! Map) return const [];
    final devices = json['devices'];
    if (devices is! Map) return const [];

    final out = <BootedDevice>[];
    for (final entry in devices.entries) {
      final runtimeDevices = entry.value;
      if (runtimeDevices is! List) continue;
      final osVersion = _osVersionFromRuntimeKey(entry.key);
      for (final d in runtimeDevices) {
        if (d is! Map) continue;
        if (d['state'] != 'Booted') continue;
        final udid = d['udid'] as String?;
        if (udid == null) continue;
        out.add(BootedDevice(
          platform: DevicePlatform.ios,
          id: udid,
          name: (d['name'] as String?) ?? 'iOS Simulator',
          osVersion: osVersion,
        ));
      }
    }
    return out;
  }

  // "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5".
  static String? _osVersionFromRuntimeKey(String key) {
    final m = RegExp(r'SimRuntime\.([A-Za-z]+)-(\d+)-(\d+)').firstMatch(key);
    if (m == null) return null;
    return '${m.group(1)} ${m.group(2)}.${m.group(3)}';
  }

  // ── app → device correlation ─────────────────────────────────────────────
  /// Recover the device an app is actually running on from its VM service URI.
  /// Critical when several simulators are booted: they share 127.0.0.1, so the
  /// port alone is ambiguous, but the listening process reveals its sim.
  Future<AppDeviceLink?> correlate(Uri vmUri, DevicePlatform platform) async {
    final port = vmUri.port;
    if (port == 0) return null;
    return switch (platform) {
      DevicePlatform.ios => _correlateIosSim(port),
      DevicePlatform.android => _correlateAndroid(port),
    };
  }

  Future<AppDeviceLink?> _correlateIosSim(int port) async {
    final pid = await _listeningPid(port);
    if (pid == null) return null;
    final ProcessResult ps;
    try {
      ps = await Process.run('ps', ['-o', 'command=', '-p', '$pid']);
    } on Object {
      return null;
    }
    if (ps.exitCode != 0) return null;
    final cmd = ps.stdout as String;
    final udid = RegExp(r'CoreSimulator/Devices/([0-9A-Fa-f-]{36})')
        .firstMatch(cmd)
        ?.group(1);
    if (udid == null) return null;
    final appName = RegExp(r'Bundle/Application/[^/]+/([^/]+)\.app')
        .firstMatch(cmd)
        ?.group(1);
    return AppDeviceLink(deviceId: udid, appName: appName);
  }

  Future<AppDeviceLink?> _correlateAndroid(int port) async {
    final ProcessResult res;
    try {
      res = await Process.run(adbPath, ['forward', '--list']);
    } on Object {
      return null;
    }
    if (res.exitCode != 0) return null;
    // Each line: "<serial> tcp:<hostPort> tcp:<devicePort>".
    for (final line in (res.stdout as String).split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[1] == 'tcp:$port') {
        return AppDeviceLink(deviceId: parts[0]);
      }
    }
    return null;
  }

  Future<int?> _listeningPid(int port) async {
    final ProcessResult res;
    try {
      res = await Process.run(
        'lsof',
        ['-nP', '-iTCP:$port', '-sTCP:LISTEN'],
      );
    } on Object {
      return null;
    }
    if (res.exitCode != 0) return null;
    for (final line in (res.stdout as String).split('\n')) {
      if (line.startsWith('COMMAND')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final pid = int.tryParse(parts[1]);
        if (pid != null) return pid;
      }
    }
    return null;
  }

  // ── connected Android devices / emulators ────────────────────────────────
  Future<List<BootedDevice>> _adbDevices() async {
    final ProcessResult res;
    try {
      res = await Process.run(adbPath, ['devices', '-l']);
    } on Object {
      return const []; // adb not installed → no Android targets
    }
    if (res.exitCode != 0) return const [];

    final out = <BootedDevice>[];
    // First line is the "List of devices attached" header.
    for (final line in (res.stdout as String).split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[1] != 'device') continue; // skip offline
      var name = parts[0];
      for (final p in parts.skip(2)) {
        if (p.startsWith('model:')) {
          name = p.substring('model:'.length).replaceAll('_', ' ');
        }
      }
      out.add(BootedDevice(
        platform: DevicePlatform.android,
        id: parts[0],
        name: name,
      ));
    }
    return out;
  }
}
