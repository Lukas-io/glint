import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';
import 'launcher.dart';

/// What stopped an installed app from opening with a reachable VM service.
enum InstalledLaunchFailure { notInstalled, alreadyRunning, toolFailed, noVmService }

/// Raised when an installed app can't be opened; [failure] says why, [detail] carries the tool output.
class InstalledLaunchError implements Exception {
  InstalledLaunchError(this.failure, this.message, {this.detail});
  final InstalledLaunchFailure failure;
  final String message;
  final String? detail;
  @override
  String toString() => 'InstalledLaunchError: $message';
}

final _appIdPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$');

/// True when [value] is a reverse-DNS app id (bundle id or package), not a folder path.
bool looksLikeAppId(String value) =>
    !value.startsWith('~') &&
    !value.startsWith('.') &&
    !value.contains('/') &&
    _appIdPattern.hasMatch(value) &&
    !Directory(value).existsSync();

/// Opens an already-installed debug build and finds its Dart VM service, with no rebuild and no flutter_tools.
class InstalledAppLauncher {
  const InstalledAppLauncher({this.adbPath = 'adb'});

  final String adbPath;

  /// Whether [udid] is a simulator on this Mac, as opposed to a physical device.
  Future<bool> isSimulator(String udid) async {
    final r = await _run('xcrun', ['simctl', 'list', 'devices', '-j']);
    return r.stdout.toString().contains(udid);
  }

  /// Reopens [appId] fresh on [deviceId] and returns the VM service URI it logged; on Android its port is the device's, for `flutter attach` to forward.
  Future<Uri> open({
    required DevicePlatform platform,
    required String deviceId,
    required String appId,
    Duration timeout = const Duration(seconds: 30),
    Duration progressEvery = const Duration(seconds: 15),
    void Function(int elapsedSec, String? phase)? onProgress,
  }) =>
      platform == DevicePlatform.ios
          ? _openIos(deviceId, appId, timeout, progressEvery, onProgress)
          : _openAndroid(deviceId, appId, timeout, progressEvery, onProgress);

  /// Throws unless [appId] is installed on [deviceId] and not running, so [open] has a fresh process to start.
  Future<void> requireClosed({
    required DevicePlatform platform,
    required String deviceId,
    required String appId,
  }) async {
    final installed = platform == DevicePlatform.ios
        ? (await _run('xcrun', ['simctl', 'get_app_container', deviceId, appId])).exitCode == 0
        : (await _adb(deviceId, ['shell', 'pm', 'path', appId])).stdout.toString().contains('package:');
    if (!installed) {
      throw InstalledLaunchError(InstalledLaunchFailure.notInstalled,
          '$appId is not installed on $deviceId');
    }
    final running = platform == DevicePlatform.ios
        ? await _iosPid(deviceId, appId)
        : await _androidPid(deviceId, appId);
    if (running != null) {
      throw InstalledLaunchError(InstalledLaunchFailure.alreadyRunning,
          '$appId is already running on $deviceId');
    }
  }

  Future<Uri> _openIos(String udid, String appId, Duration timeout,
      Duration progressEvery, void Function(int, String?)? onProgress) async {
    onProgress?.call(0, 'opening $appId');
    final stream = await _IosLogStream.start(udid);
    try {
      final launch = await _run('xcrun', ['simctl', 'launch', udid, appId]);
      final pid = int.tryParse(
          RegExp(r':\s*(\d+)\s*$').firstMatch(launch.stdout.toString().trim())?.group(1) ?? '');
      if (launch.exitCode != 0 || pid == null) {
        throw InstalledLaunchError(InstalledLaunchFailure.toolFailed,
            'simctl could not launch $appId on $udid',
            detail: _firstNonEmpty(launch.stderr, launch.stdout));
      }
      var triedLogShow = false;
      final uri = await _awaitUri(timeout, progressEvery, onProgress,
          poll: const Duration(milliseconds: 250), probe: (elapsed) async {
        final fromStream = _uriForPid(stream.text, pid);
        if (fromStream != null || triedLogShow || elapsed < const Duration(seconds: 8)) {
          return fromStream;
        }
        triedLogShow = true;
        final shown = await _run('xcrun', [
          'simctl', 'spawn', udid, 'log', 'show', '--last', '2m', '--style', 'compact',
          '--predicate',
          'processID == $pid AND eventMessage CONTAINS "Dart VM service is listening"',
        ]);
        return _uriForPid(shown.stdout.toString(), pid);
      });
      return uri;
    } finally {
      stream.stop();
    }
  }

  Future<Uri> _openAndroid(String serial, String appId, Duration timeout,
      Duration progressEvery, void Function(int, String?)? onProgress) async {
    onProgress?.call(0, 'opening $appId');
    final start = await _adb(serial, [
      'shell', 'monkey', '-p', appId, '-c', 'android.intent.category.LAUNCHER', '1',
    ]);
    if (start.exitCode != 0 || start.stdout.toString().contains('No activities found')) {
      throw InstalledLaunchError(InstalledLaunchFailure.toolFailed,
          'could not start $appId on $serial: it has no launcher activity',
          detail: _firstNonEmpty(start.stderr, start.stdout));
    }
    final stopwatch = Stopwatch()..start();
    int? pid;
    while (pid == null && stopwatch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      pid = await _androidPid(serial, appId);
    }
    if (pid == null) {
      throw InstalledLaunchError(InstalledLaunchFailure.toolFailed,
          '$appId did not start a process on $serial');
    }
    final remaining = timeout - stopwatch.elapsed;
    return _awaitUri(remaining, progressEvery, onProgress,
        poll: const Duration(seconds: 1), probe: (_) async {
      final log = await _adb(serial, ['logcat', '-d', '--pid=$pid']);
      return _firstUri(log.stdout.toString());
    });
  }

  Future<Uri> _awaitUri(
    Duration timeout,
    Duration progressEvery,
    void Function(int, String?)? onProgress, {
    required Duration poll,
    required Future<Uri?> Function(Duration elapsed) probe,
  }) async {
    final stopwatch = Stopwatch()..start();
    var nextUpdate = progressEvery;
    while (stopwatch.elapsed < timeout) {
      final uri = await probe(stopwatch.elapsed);
      if (uri != null) return uri;
      if (stopwatch.elapsed >= nextUpdate) {
        onProgress?.call(stopwatch.elapsed.inSeconds, 'waiting for the app to report its VM service');
        nextUpdate += progressEvery;
      }
      await Future<void>.delayed(poll);
    }
    throw InstalledLaunchError(InstalledLaunchFailure.noVmService,
        'the app opened but reported no Dart VM service within ${timeout.inSeconds}s');
  }

  Future<int?> _iosPid(String udid, String appId) async {
    final r = await _run('xcrun', ['simctl', 'spawn', udid, 'launchctl', 'list']);
    for (final line in r.stdout.toString().split('\n')) {
      if (!line.contains('UIKitApplication:$appId[')) continue;
      final pid = int.tryParse(line.trim().split(RegExp(r'\s+')).first);
      if (pid != null) return pid;
    }
    return null;
  }

  Future<int?> _androidPid(String serial, String appId) async {
    final r = await _adb(serial, ['shell', 'pidof', appId]);
    if (r.exitCode != 0) return null;
    return int.tryParse(r.stdout.toString().trim().split(RegExp(r'\s+')).first);
  }

  static Uri? _uriForPid(String log, int pid) {
    for (final line in log.split('\n')) {
      if (line.contains('[$pid:')) {
        final uri = _firstUri(line);
        if (uri != null) return uri;
      }
    }
    return null;
  }

  static Uri? _firstUri(String text) {
    final match = RegExp(r'The Dart VM service is listening on (\S+)').firstMatch(text);
    final raw = match?.group(1);
    if (raw == null || !AppLauncher.vmUriPattern.hasMatch(raw)) return null;
    return Uri.tryParse(raw);
  }

  Future<ProcessResult> _adb(String serial, List<String> args) =>
      _run(adbPath, ['-s', serial, ...args]);

  Future<ProcessResult> _run(String exe, List<String> args) async {
    try {
      return await Process.run(exe, args).timeout(const Duration(seconds: 20));
    } on Object catch (e) {
      throw InstalledLaunchError(InstalledLaunchFailure.toolFailed,
          'could not run $exe', detail: '$e');
    }
  }

  static String? _firstNonEmpty(Object? a, Object? b) {
    for (final v in [a, b]) {
      final s = v?.toString().trim() ?? '';
      if (s.isNotEmpty) return s;
    }
    return null;
  }
}

/// A running `log stream` on a simulator, filtered to Flutter's VM service line and ready before it is returned.
class _IosLogStream {
  _IosLogStream._(this._process);

  final Process _process;
  String text = '';

  static Future<_IosLogStream> start(String udid) async {
    final Process process;
    try {
      process = await Process.start('xcrun', [
        'simctl', 'spawn', udid, 'log', 'stream', '--style', 'compact',
        '--predicate', 'eventMessage CONTAINS "Dart VM service is listening"',
      ]);
    } on Object catch (e) {
      throw InstalledLaunchError(InstalledLaunchFailure.toolFailed,
          'could not start the simulator log stream', detail: '$e');
    }
    final stream = _IosLogStream._(process);
    final ready = Completer<void>();
    process.stdout.transform(utf8.decoder).listen((chunk) {
      stream.text += chunk;
      if (!ready.isCompleted) ready.complete();
    });
    unawaited(process.stderr.drain<void>());
    await ready.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    return stream;
  }

  void stop() => _process.kill();
}
