import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart';

import '../observability/call_progress.dart';
import '../observability/telemetry/phase_key.dart';
import 'shipped_files.dart';
import 'bounded_process.dart';
import 'cache_prune.dart' show markHelperUsed;
import 'process_state.dart';
import 'result.dart';

/// Must equal `runnerProtocol` in native/ios_xctest_runner/UITests/Router.swift.
const int expectedRunnerProtocol = 5;

/// The runner's Xcode project relative to glint's package root.
const String kRunnerProject = 'native/ios_xctest_runner/GlintRunner.xcodeproj';

/// Raised when the runner cannot be built, started or reached; [nextSteps] say what to do.
class XcTestRunnerError implements Exception {
  XcTestRunnerError(this.message,
      {this.detail, this.nextSteps = const [], this.errorKind = GlintErrorKind.backendToolError});
  final String message;
  final GlintErrorKind errorKind;
  final String? detail;
  final List<String> nextSteps;
  @override
  String toString() => 'XcTestRunnerError: $message${detail == null ? '' : ' ($detail)'}';
}

/// Sends one request to the runner and returns its status code and decoded JSON body.
typedef RunnerHttp = Future<(int, Map<String, Object?>)> Function(
    String method, Uri uri, Map<String, Object?>? body, Duration timeout);

/// Builds, starts and drives glint's XCUITest runner on one simulator.
class XcTestRunner {
  XcTestRunner({
    required this.udid,
    required this.projectPath,
    required this.cacheDir,
    int? port,
    RunnerHttp? http,
  })  : port = port ?? portFor(udid),
        _http = http ?? _defaultHttp;

  final String udid;
  final String projectPath;

  /// Holds the build (per Xcode version) and the runner's log.
  final String cacheDir;
  final int port;
  final RunnerHttp _http;
  Process? _process;
  bool _dead = false;
  bool _suspect = false;
  Future<void>? _recovery;
  int _generation = 0;

  /// The longest a runner build may run before its xcodebuild is stopped.
  static const Duration buildCeiling = Duration(minutes: 6);

  /// The stamp the runner was started with: its sources and the Xcode its build is keyed to.
  late final String identity = '${sourcesStamp()}@${cacheDir.split('/').last}';

  /// A stable port per simulator, so a runner left by an earlier glint is found again.
  static int portFor(String udid) {
    var h = 0x811c9dc5;
    for (final c in udid.toUpperCase().codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return 22100 + h % 800;
  }

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// The registry purpose of the runner's xcodebuild.
  static const String runnerPurpose = 'xctest-runner';

  /// The runner's status, retried for a runner this process started and still holds, since a busy runner can miss one 2 s ping and must not be replaced for it.
  Future<_RunnerStatus?> _statusOwn() async {
    final first = await _status();
    if (first != null || ProcessRegistry.instance.find(runnerPurpose, device: udid) == null) return first;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final again = await _status();
      if (again != null) return again;
    }
    return null;
  }

  /// Whether a runner answering on [port] speaks this protocol and was started from these sources on this Xcode.
  Future<bool> isCurrent() async => _isCurrent(await _status());

  bool _isCurrent(_RunnerStatus? status) =>
      status != null && status.protocol == expectedRunnerProtocol && status.stamp == identity;

  Future<_RunnerStatus?> _status() async {
    try {
      final (code, body) = await _http('GET', _uri('/status'), null, const Duration(seconds: 2));
      if (code != 200) return null;
      return (protocol: (body['runner'] as num?)?.toInt(), stamp: body['stamp'] as String?);
    } on Object {
      return null;
    }
  }

  /// The screen size in points, or null when the runner does not say.
  Future<({double w, double h})?> screenPoints() async {
    try {
      final screen = (await call('GET', '/status', timeout: const Duration(seconds: 5)))['screen'];
      if (screen is! List || screen.length != 2) return null;
      return (w: (screen[0] as num).toDouble(), h: (screen[1] as num).toDouble());
    } on Object {
      return null;
    }
  }

  /// The first of [bundleIds] that is in the foreground, or null when none is.
  Future<String?> frontmost(List<String> bundleIds) async {
    if (bundleIds.isEmpty) return null;
    final reply = await call('GET', '/frontmost?apps=${Uri.encodeQueryComponent(bundleIds.join(','))}',
        timeout: const Duration(seconds: 5));
    return reply['app'] as String?;
  }

  /// Reuses a runner already answering from these same sources, else builds (once per Xcode) and starts one; [onPhase] names each slow step.
  Future<void> ensureStarted(
      {void Function(String phase)? onPhase, Duration timeout = const Duration(seconds: 180)}) async {
    final running = await _statusOwn() ?? await _clearStuckHost();
    if (_isCurrent(running)) {
      _dead = false;
      _suspect = false;
      return;
    }
    if (running != null) await _retire();
    final xctestrun = await build(onPhase: onPhase);
    onPhase?.call('starting the XCTest runner on $udid');
    Directory(cacheDir).createSync(recursive: true);
    final log = File('$cacheDir/runner-$udid.log').openWrite();
    final process = await startHelper(
        runnerPurpose,
        'xcodebuild',
        [
          'test-without-building',
          '-xctestrun',
          xctestrun,
          '-destination',
          'platform=iOS Simulator,id=$udid',
          '-only-testing:GlintRunnerUITests/RunnerTests/testServe',
        ],
        device: udid,
        owner: 'sim:$udid',
        life: HelperLife.attachment,
        environment: {
          'TEST_RUNNER_GLINT_RUNNER_PORT': '$port',
          'TEST_RUNNER_GLINT_RUNNER_PARENT_PID': '$pid',
          'TEST_RUNNER_GLINT_RUNNER_STAMP': identity,
        });
    CallProgress.release(process);
    _process = process;
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);
    var exited = false;
    unawaited(process.exitCode.then((_) {
      exited = true;
      log.close().ignore();
    }));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isCurrent()) {
        _dead = false;
        _suspect = false;
        _generation++;
        return;
      }
      if (exited) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await stop();
    throw XcTestRunnerError(
      exited
          ? 'the XCTest runner exited before it answered'
          : 'the XCTest runner did not answer within ${timeout.inSeconds}s',
      detail: 'log: $cacheDir/runner-$udid.log',
      nextSteps: const ['read the runner log for the xcodebuild error', 'or attach again with iosBackend:bridge'],
    );
  }

  /// A build per runner source stamp, so another glint version's runner is never rebuilt over this one.
  String buildDirFor(String stamp) => '$cacheDir/build-$stamp';

  static final Map<String, _BuildInFlight> _buildsInFlight = {};

  /// Problems met while building that did not stop it, for the attach reply.
  final List<String> buildWarnings = [];

  /// The runner's .xctestrun, building it first when this Xcode has none for these sources; one build per source stamp at a time, across simulators and glint processes, and a caller that joins one running hears its phases too.
  Future<String> build({void Function(String phase)? onPhase}) {
    final stamp = sourcesStamp();
    final dir = buildDirFor(stamp);
    final running = _buildsInFlight[dir];
    if (running != null) {
      running.join(onPhase);
      return running.future;
    }
    final fresh = _BuildInFlight();
    fresh.join(onPhase);
    _buildsInFlight[dir] = fresh;
    fresh.future = _buildLocked(dir, stamp, fresh.announce).whenComplete(() {
      _buildsInFlight.remove(dir);
    });
    return fresh.future;
  }

  String? _reusableBuild(String dir, String stamp) {
    final existing = findXctestrun('$dir/Build/Products');
    if (existing == null || _builtFrom(dir) != stamp) return null;
    markHelperUsed('$dir/.sources');
    return existing;
  }

  Future<String> _buildLocked(String dir, String stamp, void Function(String phase) onPhase) async {
    final ready = _reusableBuild(dir, stamp);
    if (ready != null) return ready;
    Directory(cacheDir).createSync(recursive: true);
    final lock = File('$dir.lock').openSync(mode: FileMode.append);
    try {
      await _acquire(lock, onPhase);
      final builtMeanwhile = _reusableBuild(dir, stamp);
      if (builtMeanwhile != null) return builtMeanwhile;
      if (findXctestrun('$dir/Build/Products') != null && Directory(dir).existsSync()) {
        Directory(dir).deleteSync(recursive: true);
      }
      const phase = 'building the iOS runner (kept for the next attach)';
      onPhase(phase);
      final r = await CallProgress.during(phase, () => _buildBounded(dir), key: usageProcessKey('xcodebuild', null));
      final built = findXctestrun('$dir/Build/Products');
      if (r.exitCode == 0 && built != null) File('$dir/.sources').writeAsStringSync(stamp);
      if (r.exitCode != 0 || built == null) {
        throw XcTestRunnerError('could not build the XCTest runner',
            detail: 'xcodebuild exited ${r.exitCode}; ${_buildDigest(r.lines)}',
            nextSteps: const [
              'check that Xcode and an iOS Simulator SDK are installed',
              'or attach again with iosBackend:bridge'
            ]);
      }
      return built;
    } finally {
      lock.closeSync();
    }
  }

  static const _lockHeldErrnos = {11, 13, 35};

  /// Takes the build lock, polling while another glint process holds it, for as long as a build may run; any other lock error (a file system without locks) builds without it.
  Future<void> _acquire(RandomAccessFile lock, void Function(String phase) onPhase) async {
    final waited = Stopwatch()..start();
    var announced = false;
    while (true) {
      try {
        lock.lockSync(FileLock.exclusive);
        return;
      } on FileSystemException catch (e) {
        if (!_lockHeldErrnos.contains(e.osError?.errorCode)) {
          buildWarnings.add(
              'the iOS runner build could not be locked (${e.osError?.message ?? e.message}), so a second glint building it at once may collide');
          return;
        }
        if (waited.elapsed > buildCeiling + const Duration(seconds: 30)) {
          throw XcTestRunnerError('another glint process kept building the iOS runner',
              errorKind: GlintErrorKind.toolTimeout,
              detail: 'its build lock ${lock.path} was held for ${waited.elapsed.inMinutes} min',
              nextSteps: const [
                'retry once; the other build may have finished',
                'or attach again with iosBackend:bridge',
              ]);
        }
        if (!announced) onPhase('waiting for another glint to finish building the iOS runner');
        announced = true;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<({int exitCode, List<String> lines})> _buildBounded(String derivedData) async {
    final lines = <String>[];
    Future<void> collect(Stream<List<int>> stream) =>
        consume(stream.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()), (line) {
          if (line.trim().isEmpty) return;
          lines.add(line);
          if (lines.length > _buildLinesKept) lines.removeAt(0);
        });

    final process = await startManaged(
        'xcodebuild',
        [
          'build-for-testing',
          '-project',
          projectPath,
          '-scheme',
          'GlintRunner',
          '-destination',
          'generic/platform=iOS Simulator',
          '-derivedDataPath',
          derivedData,
          'CODE_SIGNING_ALLOWED=NO',
        ],
        label: 'xcodebuild build-for-testing for the runner');
    final reading = [collect(process.stdout), collect(process.stderr)];
    try {
      final code = await process.exitCode.timeout(buildCeiling);
      await settleOutput(reading);
      return (exitCode: code, lines: lines);
    } on TimeoutException {
      await killProcessTree(process);
      await settleOutput(reading);
      throw XcTestRunnerError('building the XCTest runner did not finish within ${buildCeiling.inMinutes} min',
          detail: 'xcodebuild was stopped; ${_buildDigest(lines)}',
          errorKind: GlintErrorKind.toolTimeout,
          nextSteps: const [
            'retry once; a cold build on a loaded Mac can need a few more minutes and the finished parts are cached',
            'or attach again with iosBackend:bridge',
            'check the Mac is not swapping or building elsewhere (`uptime` load)',
          ]);
    }
  }

  static const int _buildLinesKept = 400;

  /// The compiler errors found anywhere in [lines], then the last few lines.
  static String _buildDigest(List<String> lines) {
    final errors = lines.where((l) => l.contains('error:')).toSet().take(5).toList();
    final last = lines.length <= 3 ? lines : lines.sublist(lines.length - 3);
    return [if (errors.isNotEmpty) 'errors: ${errors.join(' | ')}', 'last lines: ${last.join(' | ')}'].join('; ');
  }

  /// A hash of the runner's Swift sources, so a glint update with a changed runner rebuilds it.
  String sourcesStamp() {
    var h = 0x811c9dc5;
    final root = Directory(projectPath).parent;
    if (!root.existsSync()) return '';
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.swift') || f.path.endsWith('.pbxproj'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      for (final b in f.readAsBytesSync()) {
        h = ((h ^ b) * 0x01000193) & 0xffffffff;
      }
    }
    return h.toRadixString(16);
  }

  String? _builtFrom(String dir) {
    final f = File('$dir/.sources');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// The first .xctestrun under [dir], or null.
  static String? findXctestrun(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return null;
    for (final f in d.listSync()) {
      if (f is File && f.path.endsWith('.xctestrun')) return f.path;
    }
    return null;
  }

  /// Calls [path] on the runner within [timeout]; throws [XcTestRunnerError] with the runner's own reason on failure. A slow call only makes the runner suspect: the next call first waits for it to answer, and replaces it only if it stays silent, is stopped or is gone.
  Future<Map<String, Object?>> call(String method, String path,
      {Map<String, Object?>? body, Duration timeout = const Duration(seconds: 30)}) async {
    if (_dead) {
      await _recover(settle: false);
    } else if (_suspect) {
      await _recover(settle: true);
    } else if (_recovery != null) {
      await _recovery;
    }
    final generation = _generation;
    final (int, Map<String, Object?>) reply;
    try {
      reply = await _send(method, path, body, timeout);
      _suspect = false;
    } on Object catch (e) {
      final verdict = await _noteFailure(e, generation);
      throw XcTestRunnerError('the XCTest runner did not answer $method $path',
          detail: '$e',
          errorKind: e is TimeoutException ? GlintErrorKind.toolTimeout : GlintErrorKind.backendToolError,
          nextSteps: switch (verdict) {
            _Verdict.dead => const ['the runner is gone or stopped; the next call replaces it with a fresh one'],
            _Verdict.suspect => const [
                'the runner may only be busy: retry once, the next call waits for it before deciding',
                'if it repeats, attach again to restart the runner',
              ],
            _Verdict.replaced => const ['the runner was replaced while this call ran: retry'],
          });
    }
    final (code, json) = reply;
    if (code != 200) {
      throw XcTestRunnerError('the XCTest runner refused $method $path: ${json['error'] ?? code}',
          detail: json['detail'] as String?);
    }
    return json;
  }

  Future<(int, Map<String, Object?>)> _send(String method, String path, Map<String, Object?>? body, Duration timeout) {
    final done = Completer<(int, Map<String, Object?>)>();
    _http(method, _uri(path), body, timeout).timeout(timeout).then((reply) {
      if (!done.isCompleted) done.complete(reply);
    }, onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    });
    Timer? watch;
    void arm(Duration after) {
      watch = Timer(after, () async {
        if (done.isCompleted) return;
        final host = await _host();
        if (done.isCompleted) return;
        if (host == ProcessLife.stopped) {
          done.completeError(const _RunnerStopped());
        } else {
          arm(_stoppedRecheckEvery);
        }
      });
    }

    arm(_stoppedFirstCheck);
    return done.future.whenComplete(() => watch?.cancel());
  }

  static const Duration _stoppedFirstCheck = Duration(seconds: 3);

  static const Duration _stoppedRecheckEvery = Duration(seconds: 10);

  static const Duration _drainWindow = Duration(seconds: 8);

  Future<ProcessLife> _host() async {
    final owners = await portOwners(port);
    if (!owners.known) return ProcessLife.unknown;
    if (owners.pids.isEmpty) return ProcessLife.gone;
    final checks = await Future.wait([for (final p in owners.pids) checkProcess(p)]);
    if (checks.any((c) => c.life == ProcessLife.stopped)) return ProcessLife.stopped;
    return checks.any((c) => c.life == ProcessLife.unknown) ? ProcessLife.unknown : ProcessLife.running;
  }

  Future<_Verdict> _noteFailure(Object error, int generation) async {
    if (generation != _generation) return _Verdict.replaced;
    final refused = error is SocketException && '$error'.contains('refused');
    final host = refused || error is _RunnerStopped ? ProcessLife.gone : await _host();
    if (generation != _generation) return _Verdict.replaced;
    if (host == ProcessLife.gone || host == ProcessLife.stopped) {
      _dead = true;
      return _Verdict.dead;
    }
    _suspect = true;
    return _Verdict.suspect;
  }

  /// Settles a suspect runner, then replaces it if needed; one recovery runs at a time and concurrent calls join it.
  Future<void> _recover({required bool settle}) =>
      _recovery ??= _recoverNow(settle).whenComplete(() => _recovery = null);

  Future<void> _recoverNow(bool settle) async {
    final seen = _generation;
    if (settle && await _answersWithin(_drainWindow)) {
      _suspect = false;
      return;
    }
    if (_generation != seen) return;
    await _retire();
    await CallProgress.during('restarting the iOS runner', () => ensureStarted(timeout: const Duration(seconds: 60)),
        key: usageProcessKey('xcodebuild', null));
  }

  Future<bool> _answersWithin(Duration window) async {
    final deadline = DateTime.now().add(window);
    while (true) {
      final host = await _host();
      if (host == ProcessLife.gone || host == ProcessLife.stopped) return false;
      if (await _status() != null) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
    }
  }

  /// A runner already holding the port without this glint's own: ends a stopped one, gives a busy one a window to answer, ends it if it stays silent; its status when it answers.
  Future<_RunnerStatus?> _clearStuckHost() async {
    final host = await _host();
    if (host == ProcessLife.running) {
      if (await _answersWithin(const Duration(seconds: 5))) return _status();
      await _retire();
    } else if (host == ProcessLife.stopped) {
      await _retire();
    }
    return null;
  }

  /// Ends the runner and, when its test host still holds the port (a stopped one does), terminates that host too.
  Future<void> _retire() async {
    await stop();
    final owners = await portOwners(port);
    if (!owners.known || owners.pids.isEmpty) return;
    await runBounded('xcrun', ['simctl', 'terminate', udid, _runnerHostBundle],
            timeout: const Duration(seconds: 8), phase: 'ending the stuck XCTest runner')
        .then<void>((_) {}, onError: (Object _) {});
  }

  static const String _runnerHostBundle = 'dev.glint.runner.uitests.xctrunner';

  /// Asks the runner to finish its test, then ends the xcodebuild process glint started.
  Future<void> stop() async {
    try {
      await _http('POST', _uri('/shutdown'), const {}, const Duration(seconds: 2));
    } on Object {
      // already gone
    }
    final own = _process;
    _process = null;
    if (own != null) await ProcessRegistry.instance.stop(runnerPurpose, device: udid, only: own);
  }

  static Future<(int, Map<String, Object?>)> _defaultHttp(
      String method, Uri uri, Map<String, Object?>? body, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = text.isEmpty ? const <String, Object?>{} : jsonDecode(text);
      return (res.statusCode, decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{'value': decoded});
    } finally {
      client.close(force: true);
    }
  }
}

/// The runner's Xcode project shipped with glint, or null.
String? locateRunnerProject({String? scriptPath}) => shippedPath(kRunnerProject, scriptPath: scriptPath);

typedef _RunnerStatus = ({int? protocol, String? stamp});

enum _Verdict { dead, suspect, replaced }

class _RunnerStopped implements Exception {
  const _RunnerStopped();
  @override
  String toString() => 'the runner process is stopped (ps state T)';
}

/// A runner build running now, with everyone waiting on it hearing its phases.
class _BuildInFlight {
  late final Future<String> future;
  final List<void Function(String phase)> _listeners = [];
  String? _phase;

  void join(void Function(String phase)? listener) {
    if (listener == null) return;
    _listeners.add(listener);
    final phase = _phase;
    if (phase != null) listener(phase);
  }

  void announce(String phase) {
    _phase = phase;
    for (final l in _listeners) {
      l(phase);
    }
  }
}
