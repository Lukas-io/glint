import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Must equal `runnerProtocol` in native/ios_xctest_runner/UITests/Router.swift.
const int expectedRunnerProtocol = 1;

/// The runner's Xcode project relative to glint's package root.
const String kRunnerProject = 'native/ios_xctest_runner/GlintRunner.xcodeproj';

/// Raised when the runner cannot be built, started or reached; [nextSteps] say what to do.
class XcTestRunnerError implements Exception {
  XcTestRunnerError(this.message, {this.detail, this.nextSteps = const []});
  final String message;
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

  /// A stable port per simulator, so a runner left by an earlier glint is found again.
  static int portFor(String udid) {
    var h = 0x811c9dc5;
    for (final c in udid.toUpperCase().codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return 22100 + h % 800;
  }

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  /// The runner's protocol number when one answers on [port], else null.
  Future<int?> ping() async {
    try {
      final (code, body) = await _http('GET', _uri('/status'), null, const Duration(seconds: 2));
      return code == 200 ? (body['runner'] as num?)?.toInt() : null;
    } on Object {
      return null;
    }
  }

  /// Reuses a runner already answering, else builds (once per Xcode) and starts one; [onPhase] names each slow step.
  Future<void> ensureStarted({void Function(String phase)? onPhase, Duration timeout = const Duration(seconds: 180)}) async {
    final fresh = _builtFrom() == sourcesStamp();
    final running = await ping();
    if (running == expectedRunnerProtocol && fresh) return;
    if (running != null) await stop();
    final xctestrun = await build(onPhase: onPhase);
    onPhase?.call('starting the XCTest runner on $udid');
    Directory(cacheDir).createSync(recursive: true);
    final log = File('$cacheDir/runner-$udid.log').openWrite();
    final process = await Process.start('xcodebuild', [
      'test-without-building',
      '-xctestrun', xctestrun,
      '-destination', 'platform=iOS Simulator,id=$udid',
      '-only-testing:GlintRunnerUITests/RunnerTests/testServe',
    ], environment: {'TEST_RUNNER_GLINT_RUNNER_PORT': '$port'});
    _process = process;
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await ping() == expectedRunnerProtocol) return;
      if (exited) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await stop();
    throw XcTestRunnerError(
      exited ? 'the XCTest runner exited before it answered' : 'the XCTest runner did not answer within ${timeout.inSeconds}s',
      detail: 'log: $cacheDir/runner-$udid.log',
      nextSteps: const ['read the runner log for the xcodebuild error', 'or attach again with iosBackend:bridge'],
    );
  }

  /// The runner's .xctestrun, building it first when this Xcode has none.
  Future<String> build({void Function(String phase)? onPhase}) async {
    final stamp = sourcesStamp();
    final existing = findXctestrun('$cacheDir/build/Build/Products');
    if (existing != null && _builtFrom() == stamp) return existing;
    onPhase?.call('building the XCTest runner (first use on this Xcode, about a minute)');
    final r = await Process.run('xcodebuild', [
      'build-for-testing',
      '-project', projectPath,
      '-scheme', 'GlintRunner',
      '-destination', 'generic/platform=iOS Simulator',
      '-derivedDataPath', '$cacheDir/build',
      'CODE_SIGNING_ALLOWED=NO',
    ]);
    final built = findXctestrun('$cacheDir/build/Build/Products');
    if (r.exitCode == 0 && built != null) File('$cacheDir/build/.sources').writeAsStringSync(stamp);
    if (r.exitCode != 0 || built == null) {
      final tail = '${r.stdout}\n${r.stderr}'.trim().split('\n').where((l) => l.contains('error')).take(5).join('\n');
      throw XcTestRunnerError('could not build the XCTest runner',
          detail: tail.isEmpty ? 'xcodebuild exited ${r.exitCode}' : tail,
          nextSteps: const ['check that Xcode and an iOS Simulator SDK are installed', 'or attach again with iosBackend:bridge']);
    }
    return built;
  }

  /// A hash of the runner's Swift sources, so a glint update with a changed runner rebuilds it.
  String sourcesStamp() {
    var h = 0x811c9dc5;
    final root = Directory(projectPath).parent;
    final files = root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.swift') || f.path.endsWith('.pbxproj')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      for (final b in f.readAsBytesSync()) {
        h = ((h ^ b) * 0x01000193) & 0xffffffff;
      }
    }
    return h.toRadixString(16);
  }

  String? _builtFrom() {
    final f = File('$cacheDir/build/.sources');
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

  /// Calls [path] on the runner; throws [XcTestRunnerError] with the runner's own reason on failure.
  Future<Map<String, Object?>> call(String method, String path,
      {Map<String, Object?>? body, Duration timeout = const Duration(seconds: 30)}) async {
    final (int, Map<String, Object?>) reply;
    try {
      reply = await _http(method, _uri(path), body, timeout);
    } on Object catch (e) {
      throw XcTestRunnerError('the XCTest runner did not answer $method $path',
          detail: '$e', nextSteps: const ['attach again to restart the runner']);
    }
    final (code, json) = reply;
    if (code != 200) {
      throw XcTestRunnerError('the XCTest runner refused $method $path: ${json['error'] ?? code}',
          detail: json['detail'] as String?);
    }
    return json;
  }

  /// Asks the runner to finish its test, then ends the xcodebuild process glint started.
  Future<void> stop() async {
    try {
      await _http('POST', _uri('/shutdown'), const {}, const Duration(seconds: 2));
    } on Object {
      // already gone
    }
    _process?.kill();
    _process = null;
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

/// Walks up from the running script to glint's package and returns the runner's Xcode project, or null.
String? locateRunnerProject({String? scriptPath}) {
  Directory dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    return null;
  }
  for (var i = 0; i < 6; i++) {
    final p = '${dir.path}/$kRunnerProject';
    if (Directory(p).existsSync()) return p;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
