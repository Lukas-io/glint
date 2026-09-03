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

/// The device an app runs on, recovered from a VM service port, plus iOS bundle identity from Info.plist.
class AppDeviceLink {
  const AppDeviceLink({
    required this.deviceId,
    this.appName,
    this.bundleId,
    this.displayName,
  });

  /// iOS simulator UDID or Android serial that hosts the app on this port.
  final String deviceId;

  /// `.app` bundle folder name (iOS) — usually the generic "Runner".
  final String? appName;

  /// CFBundleIdentifier, e.g. `com.app.aetrust`.
  final String? bundleId;

  /// CFBundleDisplayName / CFBundleName, e.g. `Aetrust`.
  final String? displayName;
}

/// One running Flutter app, correlated to its device and identity as far as
/// the host can tell without connecting to the VM.
class RunningApp {
  const RunningApp({
    required this.vmUri,
    this.platform,
    this.deviceId,
    this.deviceName,
    this.bundleId,
    this.displayName,
    this.appName,
  });

  final Uri vmUri;
  final DevicePlatform? platform;
  final String? deviceId;
  final String? deviceName;
  final String? bundleId;
  final String? displayName;
  final String? appName;

  /// Best human label; null when nothing but the URI is known.
  String? get label => displayName ?? bundleId ?? appName;

  /// Case-insensitive match on app identity or device (id or name prefix).
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    if (deviceId?.toLowerCase() == q) return true;
    for (final s in [displayName, bundleId, appName, deviceName]) {
      if (s == null) continue;
      final v = s.toLowerCase();
      if (v == q || v.startsWith(q)) return true;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
        'vmUri': vmUri.toString(),
        if (platform != null) 'platform': platform!.name,
        if (deviceId != null) 'device': deviceId,
        if (deviceName != null) 'deviceName': deviceName,
        if (label != null) 'app': label,
        if (bundleId != null) 'bundleId': bundleId,
      };
}

/// Running Flutter VM URIs + booted devices. Uncorrelated by design — a 127.0.0.1 URI carries no device identity; `attach` pairs them later.
class DiscoveryResult {
  const DiscoveryResult({required this.vmUris, required this.devices});

  final List<Uri> vmUris;
  final List<BootedDevice> devices;

  List<BootedDevice> devicesFor(DevicePlatform p) =>
      devices.where((d) => d.platform == p).toList();
}

/// Where `adb` lives: [explicit] first, then PATH, then the usual SDK homes
/// (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`,
/// `~/Android/Sdk`). Null when none exists — callers say so instead of
/// reporting "no android device".
String? resolveAdbPath(String? explicit, [Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final exe = Platform.isWindows ? 'adb.exe' : 'adb';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in (e['PATH'] ?? '').split(sep)) {
    if (dir.isEmpty) continue;
    final f = File('$dir/$exe');
    if (f.existsSync()) return f.path;
  }
  final home = e['HOME'] ?? e['USERPROFILE'] ?? '';
  final roots = [
    e['ANDROID_HOME'],
    e['ANDROID_SDK_ROOT'],
    if (home.isNotEmpty) '$home/Library/Android/sdk',
    if (home.isNotEmpty) '$home/Android/Sdk',
    if (e['LOCALAPPDATA'] != null) '${e['LOCALAPPDATA']}/Android/Sdk',
  ];
  for (final root in roots) {
    if (root == null || root.isEmpty) continue;
    final f = File('$root/platform-tools/$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Finds running Flutter apps + booted devices so `attach` can auto-fill omitted args.
/// Pure host inspection: `ps` for VM URIs, `xcrun simctl` for iOS sims, `adb devices` for Android.
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
  // Matches the canonical Dart VM service URI http://127.0.0.1:PORT/TOKEN=/ ;
  // restricted to Dart/Flutter process lines so unrelated localhost URLs don't leak in.
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
  /// Recover the device an app runs on from its VM service URI — when several sims share 127.0.0.1
  /// the port is ambiguous, but the listening process reveals its sim.
  /// Describe every running app in [scan]: device (iOS via the flutter_tools
  /// process chain, Android via `adb forward`) plus bundle identity when the
  /// app's Info.plist is reachable. Best-effort per app; never throws.
  Future<List<RunningApp>> describeRunningApps(DiscoveryResult scan) async {
    final out = <RunningApp>[];
    for (final uri in scan.vmUris) {
      AppDeviceLink? link;
      DevicePlatform? platform;
      try {
        link = await _correlateIosSim(uri.port, scan.devices);
        if (link != null) platform = DevicePlatform.ios;
        if (link == null && scan.devicesFor(DevicePlatform.android).isNotEmpty) {
          link = await _correlateAndroid(uri.port);
          if (link != null) platform = DevicePlatform.android;
        }
      } on Object {
        link = null;
      }
      var bundleId = link?.bundleId;
      var displayName = link?.displayName;
      if (link != null && platform == DevicePlatform.ios && displayName == null) {
        final info = await appInfoForDevice(link.deviceId);
        bundleId ??= info?.$1;
        displayName ??= info?.$2;
      }
      BootedDevice? dev;
      for (final d in scan.devices) {
        if (d.id == link?.deviceId) dev = d;
      }
      out.add(RunningApp(
        vmUri: uri,
        platform: platform ?? dev?.platform,
        deviceId: link?.deviceId,
        deviceName: dev?.name,
        bundleId: bundleId,
        displayName: displayName,
        appName: link?.appName,
      ));
    }
    return out;
  }

  Future<AppDeviceLink?> correlate(Uri vmUri, DevicePlatform platform) async {
    final port = vmUri.port;
    if (port == 0) return null;
    return switch (platform) {
      DevicePlatform.ios => _correlateIosSim(port, const []),
      DevicePlatform.android => _correlateAndroid(port),
    };
  }

  /// The port's listener is the `flutter run` tool process (DDS host), whose
  /// command line names the target with `-d <udid|name>`; the app path form
  /// (`CoreSimulator/Devices/<udid>/…/X.app`) is checked first where present.
  /// Walks up to three parents in case the listener is a helper child.
  Future<AppDeviceLink?> _correlateIosSim(
      int port, List<BootedDevice> booted) async {
    var pid = await _listeningPid(port);
    for (var hop = 0; pid != null && hop < 4; hop++) {
      final ProcessResult ps;
      try {
        ps = await Process.run('ps', ['-o', 'ppid=,command=', '-p', '$pid']);
      } on Object {
        return null;
      }
      if (ps.exitCode != 0) return null;
      final line = (ps.stdout as String).trim();
      final split = line.indexOf(' ');
      final ppid = int.tryParse(split < 0 ? line : line.substring(0, split));
      final cmd = split < 0 ? '' : line.substring(split + 1);
      final link = await linkFromCommandLine(cmd, booted, _readBundleInfo);
      if (link != null) return link;
      if (ppid == null || ppid <= 1) break;
      pid = ppid;
    }
    return null;
  }

  /// Pure: the device link a process command line reveals, if any.
  static Future<AppDeviceLink?> linkFromCommandLine(
    String cmd,
    List<BootedDevice> booted,
    Future<(String?, String?)?> Function(String appPath) readBundle,
  ) async {
    final pathUdid = RegExp(r'CoreSimulator/Devices/([0-9A-Fa-f-]{36})')
        .firstMatch(cmd)
        ?.group(1);
    if (pathUdid != null) {
      final appMatch = RegExp(r'(\S*/([^/]+)\.app)').firstMatch(cmd);
      final info =
          appMatch != null ? await readBundle(appMatch.group(1)!) : null;
      return AppDeviceLink(
        deviceId: pathUdid,
        appName: appMatch?.group(2),
        bundleId: info?.$1,
        displayName: info?.$2,
      );
    }
    final flag = RegExp(r'(?:^|\s)(?:-d|--device-id)[=\s]+("[^"]+"|\S+)')
        .firstMatch(cmd)
        ?.group(1)
        ?.replaceAll('"', '');
    if (flag == null) return null;
    if (RegExp(r'^[0-9A-Fa-f-]{36}$').hasMatch(flag)) {
      return AppDeviceLink(deviceId: flag);
    }
    final q = flag.toLowerCase();
    for (final d in booted) {
      if (d.platform != DevicePlatform.ios) continue;
      final n = d.name.toLowerCase();
      if (n == q || n.startsWith(q) || d.id.toLowerCase().startsWith(q)) {
        return AppDeviceLink(deviceId: d.id);
      }
    }
    return null;
  }

  /// (CFBundleIdentifier, CFBundleDisplayName ?? CFBundleName) from an app's
  /// Info.plist, via `plutil`. Null if unreadable.
  Future<(String?, String?)?> _readBundleInfo(String appPath) async {
    try {
      final r = await Process.run(
        'plutil',
        ['-convert', 'json', '-o', '-', '$appPath/Info.plist'],
      );
      if (r.exitCode != 0) return null;
      final j = jsonDecode(r.stdout as String);
      if (j is! Map) return null;
      return (
        j['CFBundleIdentifier'] as String?,
        (j['CFBundleDisplayName'] ?? j['CFBundleName']) as String?,
      );
    } on Object {
      return null;
    }
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

  Future<int?> _listeningPid(int port) async =>
      (await _listeningPids(port)).firstOrNull;

  Future<List<int>> _listeningPids(int port) async {
    final ProcessResult res;
    try {
      res = await Process.run('lsof', ['-nP', '-iTCP:$port', '-sTCP:LISTEN']);
    } on Object {
      return const [];
    }
    if (res.exitCode != 0) return const [];
    final pids = <int>[];
    for (final line in (res.stdout as String).split('\n')) {
      if (line.startsWith('COMMAND')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final pid = int.tryParse(parts[1]);
        if (pid != null && !pids.contains(pid)) pids.add(pid);
      }
    }
    return pids;
  }

  // ── project dir (for relaunch) ───────────────────────────────────────────
  /// Flutter project root behind a running app — the VM port's listening process (DDS) cwd, validated by pubspec.yaml.
  Future<String?> projectDirForVm(Uri vmUri) async {
    final port = vmUri.port;
    if (port == 0) return null;
    for (final pid in await _listeningPids(port)) {
      final cwd = await _cwdOf(pid);
      if (cwd != null && File('$cwd/pubspec.yaml').existsSync()) return cwd;
    }
    return null;
  }

  Future<String?> _cwdOf(int pid) async {
    final ProcessResult res;
    try {
      res = await Process.run('lsof', ['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
    } on Object {
      return null;
    }
    if (res.exitCode != 0) return null;
    for (final line in (res.stdout as String).split('\n')) {
      if (line.startsWith('n')) return line.substring(1);
    }
    return null;
  }

  // ── app identity for the CORRELATED project (precise) ────────────────────
  /// (CFBundleIdentifier, display name) from the app flutter built for
  /// [projectDir]. Tied to the exact project behind our VM ([projectDirForVm]),
  /// so it can't grab a different app that also ran on the device. Null when no
  /// built product exists (e.g. attached to an app we didn't build here).
  Future<(String?, String?)?> appInfoForProject(String projectDir) async {
    for (final variant in const ['iphonesimulator', 'iphoneos']) {
      final appDir = '$projectDir/build/ios/$variant/Runner.app';
      if (!File('$appDir/Info.plist').existsSync()) continue;
      final info = await _readBundleInfo(appDir);
      if (info != null && info.$1 != null) return info;
    }
    return null;
  }

  // ── app identity for a known device (bundle id, for kill/identity) ────────
  /// (CFBundleIdentifier, display name) of the user app running on iOS [udid],
  /// found by its `Containers/Bundle/Application/…app` process — device-global,
  /// NOT correlated to our VM. Fallback only, for when the project dir is
  /// unknown; prefer [appInfoForProject].
  ///
  /// Returns null when MORE THAN ONE distinct app is running on the sim: the
  /// scan can't tell which one owns the caller's VM, and a wrong bundleId would
  /// make kill_app terminate the wrong app. Callers fall back to the VM's
  /// authoritative package name instead of a guessed identity.
  Future<(String?, String?)?> appInfoForDevice(String udid) async {
    final ProcessResult ps;
    try {
      ps = await Process.run('ps', ['-Axww', '-o', 'command=']);
    } on Object {
      return null;
    }
    if (ps.exitCode != 0) return null;
    final appPaths = appBundlePathsForDevice(ps.stdout as String, udid);
    if (appPaths.length != 1) return null; // none, or ambiguous
    return await _readBundleInfo(appPaths.first);
  }

  /// Distinct `…app` bundle paths for [udid] found in `ps` [output]. More than
  /// one means multiple apps share the sim — the caller treats that as
  /// ambiguous. Static + pure so it's unit-testable without a live `ps`.
  static List<String> appBundlePathsForDevice(String output, String udid) {
    final re = RegExp(
      '(/\\S*/CoreSimulator/Devices/$udid/data/Containers/'
      'Bundle/Application/[^/]+/[^/]+\\.app)',
    );
    final appPaths = <String>{};
    for (final line in output.split('\n')) {
      final appPath = re.firstMatch(line)?.group(1);
      if (appPath != null) appPaths.add(appPath);
    }
    return appPaths.toList();
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
