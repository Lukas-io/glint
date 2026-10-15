import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../version.dart';
import 'bridge_download.dart';

/// Must equal `PROTOCOL` in native/ios_device_hid/src/main.rs.
const int expectedDeviceHidProtocol = 1;

/// The helper's release build relative to glint's package root.
const String kDeviceHidBuild = 'native/ios_device_hid/target/release/glint-devicehid';

/// Env var naming a helper binary to use instead of the one glint finds.
const String deviceHidEnv = 'GLINT_DEVICE_HID';

/// The release asset name of the universal macOS helper.
const String deviceHidAssetName = 'glint-devicehid-macos';

/// A failure of the Device Hub helper; [kind] is the helper's own (deviceNotFound, tunnel, developerImage, deviceBusy, unsupportedText, input, missing, ...).
class DeviceHidError implements Exception {
  DeviceHidError(this.kind, this.detail);
  final String kind;
  final String detail;

  /// What the agent can do about this failure.
  List<String> get nextSteps => switch (kind) {
        'missing' => [
            'build it with `cargo build --release` in packages/glint_mcp/$deviceHidBuildDir, or set $deviceHidEnv',
          ],
        'deviceNotFound' || 'usbmuxd' => const [
            'connect the iPhone by cable (or the same Wi-Fi with "Connect via network" on), unlock it, then retry',
          ],
        'tunnel' => const [
            'unlock the iPhone and confirm it trusts this Mac and has Developer Mode on, then retry',
          ],
        'developerImage' => const [
            'run any app on the phone from Xcode or `flutter run` once so the developer disk image mounts, then retry',
          ],
        'deviceBusy' => const ['close Device Hub (Xcode) or any other screen viewer of this phone, then retry'],
        'unsupportedText' => const [
            'only printable ASCII types through the hardware keyboard; for other text focus a Flutter field and use iosInput:auto',
          ],
        _ => const ['retry once; if it repeats, attach again'],
      };

  @override
  String toString() => 'DeviceHidError($kind): $detail';
}

const String deviceHidBuildDir = 'native/ios_device_hid';

/// glint's resident Device Hub helper for one physical iPhone: real touch, keyboard and button input over the CoreDevice tunnel.
class DeviceHid {
  DeviceHid({required this.udid, String? binary}) : _binary = binary;

  final String udid;
  final String? _binary;
  Process? _process;
  StreamIterator<String>? _lines;
  Future<void>? _starting;
  Future<void> _queue = Future.value();
  final _stderr = StringBuffer();

  bool get running => _process != null;

  /// Starts the helper once; concurrent callers share the same start.
  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_process != null) return;
    final binary = _binary ?? await ensureDeviceHid();
    final Process process;
    try {
      process = await Process.start(binary, ['--udid', udid]);
    } on ProcessException catch (e) {
      throw DeviceHidError('missing', 'cannot run $binary: ${e.message}');
    }
    _stderr.clear();
    process.stderr.transform(utf8.decoder).listen(_stderr.write);
    final lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final first = await lines.moveNext().timeout(const Duration(seconds: 20), onTimeout: () => false)
        ? _decode(lines.current)
        : null;
    if (first == null) {
      process.kill();
      throw DeviceHidError('tunnel', 'the helper did not connect within 20 s${_why()}');
    }
    if (first['ok'] == false) {
      process.kill();
      throw DeviceHidError('${first['kind']}', '${first['error']}');
    }
    if (first['ready'] != expectedDeviceHidProtocol) {
      process.kill();
      throw DeviceHidError('missing', 'the helper speaks protocol ${first['ready']}, glint expects $expectedDeviceHidProtocol; rebuild or re-download it');
    }
    _process = process;
    _lines = lines;
    unawaited(process.exitCode.then((_) {
      if (identical(_process, process)) {
        _process = null;
        _lines = null;
      }
    }));
  }

  String _why() {
    final s = _stderr.toString().trim();
    return s.isEmpty ? '' : ': ${s.split('\n').last}';
  }

  Map<String, Object?>? _decode(String line) {
    try {
      return (jsonDecode(line) as Map).cast<String, Object?>();
    } on Object {
      return null;
    }
  }

  /// Sends [request] and returns the helper's reply; calls run one at a time and throw [DeviceHidError] on failure.
  Future<Map<String, Object?>> call(Map<String, Object?> request, {Duration timeout = const Duration(seconds: 20)}) {
    final result = _queue.then((_) => _send(request, timeout));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> request, Duration timeout) async {
    await start();
    final process = _process;
    final lines = _lines;
    if (process == null || lines == null) throw DeviceHidError('tunnel', 'the helper is not running${_why()}');
    try {
      process.stdin.writeln(jsonEncode(request));
      await process.stdin.flush();
      if (!await lines.moveNext().timeout(timeout)) throw DeviceHidError('tunnel', 'the helper exited${_why()}');
    } on DeviceHidError {
      await stop();
      rethrow;
    } on Object catch (e) {
      await stop();
      throw DeviceHidError('tunnel', 'the helper stopped answering: $e');
    }
    final reply = _decode(lines.current) ?? const {'ok': false, 'kind': 'input', 'error': 'unreadable reply'};
    if (reply['ok'] != true) throw DeviceHidError('${reply['kind']}', '${reply['error']}');
    return reply;
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    _lines = null;
    if (process == null) return;
    try {
      process.stdin.writeln('{"cmd":"quit"}');
      await process.stdin.flush();
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on Object {
      process.kill();
    }
  }
}

/// Where the downloaded helper for this glint version lives, under `~/.glint/bin`.
String cachedDeviceHidPath({Map<String, String>? env}) =>
    '${(env ?? Platform.environment)['HOME'] ?? '.'}/.glint/bin/glint-devicehid-$glintVersion';

/// The helper: [deviceHidEnv], then a build inside glint's package, then the download cache; null when none exists.
String? locateDeviceHid({Map<String, String>? env, String? scriptPath}) {
  final e = env ?? Platform.environment;
  final fromEnv = e[deviceHidEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  Directory dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    dir = Directory.current;
  }
  for (var i = 0; i < 6; i++) {
    final p = '${dir.path}/$kDeviceHidBuild';
    if (File(p).existsSync()) return p;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final cached = cachedDeviceHidPath(env: e);
  return File(cached).existsSync() ? cached : null;
}

/// The helper's path, downloading this version's release asset when no copy exists; throws [DeviceHidError] kind `missing`.
Future<String> ensureDeviceHid({BytesFetcher? fetch}) async {
  final found = locateDeviceHid();
  if (found != null) return found;
  if (Platform.environment[noBridgeDownloadEnv] != null) {
    throw DeviceHidError('missing', 'no glint-devicehid helper and $noBridgeDownloadEnv is set');
  }
  final dest = cachedDeviceHidPath();
  try {
    await downloadReleaseAsset(deviceHidAssetName, dest, executable: true, fetch: fetch);
  } on BridgeDownloadError catch (e) {
    throw DeviceHidError('missing', 'could not download glint-devicehid: ${e.message}');
  }
  return dest;
}
