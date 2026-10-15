import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../version.dart';

/// Must equal `PROTOCOL` in native/android_server/src/dev/glint/server/Server.java.
const int expectedAndroidServerProtocol = 2;

/// The server's dex relative to glint's package root, as `native/android_server/build.sh` writes it.
const String kAndroidServerDex = 'native/android_server/build/glint-android-server.dex';

/// Env var naming a server dex to use instead of the one glint finds.
const String androidServerEnv = 'GLINT_ANDROID_SERVER';

const String _deviceDex = '/data/local/tmp/glint-android-server.dex';

/// Raised when the server cannot be started or stops answering.
class AndroidServerError implements Exception {
  AndroidServerError(this.message);
  final String message;
  @override
  String toString() => 'AndroidServerError: $message';
}

/// glint's resident `app_process` server on one Android device, reached over an adb-forwarded local socket.
class AndroidServer {
  AndroidServer({required this.serial, required this.adbPath, required this.dexPath});

  final String serial;
  final String adbPath;
  final String dexPath;

  Process? _process;
  Socket? _socket;
  StreamIterator<String>? _lines;
  int? _port;
  Future<void> _queue = Future.value();

  bool get running => _socket != null;

  String get _socketName => 'glint-server-${serial.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}';

  /// Pushes the dex, starts the server, and connects; throws [AndroidServerError] naming the step that failed.
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    final push = await Process.run(adbPath, ['-s', serial, 'push', dexPath, _deviceDex]);
    if (push.exitCode != 0) {
      throw AndroidServerError('adb push of the server failed: ${'${push.stderr}'.trim()}');
    }
    await Process.run(adbPath, ['-s', serial, 'shell', 'pkill', '-f', _socketName]);
    final process = await Process.start(adbPath, [
      '-s',
      serial,
      'shell',
      'CLASSPATH=$_deviceDex',
      'app_process',
      '/',
      'dev.glint.server.Server',
      _socketName,
    ]);
    _process = process;
    final stderr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final ready = Completer<int?>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'^ready (\d+)').firstMatch(line);
      if (m != null && !ready.isCompleted) ready.complete(int.parse(m.group(1)!));
    });
    unawaited(process.exitCode.then((_) {
      if (!ready.isCompleted) ready.complete(null);
    }));
    final protocol = await ready.future.timeout(timeout, onTimeout: () => null);
    if (protocol == null) {
      await stop();
      final why = stderr.toString().trim().split('\n').where((l) => l.isNotEmpty).take(3).join(' | ');
      throw AndroidServerError('the server did not start${why.isEmpty ? '' : ': $why'}');
    }
    if (protocol != expectedAndroidServerProtocol) {
      await stop();
      throw AndroidServerError('the server speaks protocol $protocol, glint expects $expectedAndroidServerProtocol');
    }
    final fwd = await Process.run(adbPath, ['-s', serial, 'forward', 'tcp:0', 'localabstract:$_socketName']);
    _port = int.tryParse('${fwd.stdout}'.trim());
    if (fwd.exitCode != 0 || _port == null) {
      await stop();
      throw AndroidServerError('adb forward failed: ${'${fwd.stderr}'.trim()}');
    }
    final socket = await Socket.connect('127.0.0.1', _port!, timeout: timeout);
    _socket = socket;
    _lines = StreamIterator(socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
  }

  /// Sends [request] and returns the server's reply; calls run one at a time.
  Future<Map<String, Object?>> call(Map<String, Object?> request, {Duration timeout = const Duration(seconds: 20)}) {
    final result = _queue.then((_) => _send(request, timeout));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> request, Duration timeout) async {
    final socket = _socket;
    final lines = _lines;
    if (socket == null || lines == null) throw AndroidServerError('the server is not running');
    try {
      socket.write('${jsonEncode(request)}\n');
      await socket.flush();
      if (!await lines.moveNext().timeout(timeout)) throw AndroidServerError('the server closed the connection');
      return (jsonDecode(lines.current) as Map).cast<String, Object?>();
    } on Object catch (e) {
      await stop();
      throw e is AndroidServerError ? e : AndroidServerError('the server stopped answering: $e');
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;
    _lines = null;
    try {
      socket?.write('{"cmd":"quit"}\n');
      await socket?.flush();
      await socket?.close();
    } on Object {
      // already gone
    }
    socket?.destroy();
    _process?.kill();
    _process = null;
    if (_port != null) {
      await Process.run(adbPath, ['-s', serial, 'forward', '--remove', 'tcp:$_port']);
      _port = null;
    }
  }
}

/// The server dex: [androidServerEnv], then a build inside glint's package, then the download cache; null when none exists.
String? locateAndroidServerDex({Map<String, String>? env, String? scriptPath}) {
  final e = env ?? Platform.environment;
  final fromEnv = e[androidServerEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  Directory dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    dir = Directory.current;
  }
  for (var i = 0; i < 6; i++) {
    final p = '${dir.path}/$kAndroidServerDex';
    if (File(p).existsSync()) return p;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final cached = cachedAndroidServerPath(env: e);
  return File(cached).existsSync() ? cached : null;
}

/// Where the downloaded server for this glint version lives, under `~/.glint/bin`.
String cachedAndroidServerPath({Map<String, String>? env}) =>
    '${(env ?? Platform.environment)['HOME'] ?? '.'}/.glint/bin/glint-android-server-$glintVersion.dex';

/// The server's Java sources inside glint's package, found by walking up from the running script; null when this install has none.
Directory? locateAndroidServerSources({String? scriptPath}) {
  Directory dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    dir = Directory.current;
  }
  for (var i = 0; i < 6; i++) {
    final src = Directory('${dir.path}/native/android_server/src');
    if (src.existsSync()) return src;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Builds the server dex from glint's own sources into [dest] (javac against the newest android.jar, then d8), as `native/android_server/build.sh` does, for a glint version whose release carries no prebuilt one.
Future<String> buildAndroidServerDex(String dest, {String? adbPath, Map<String, String>? env}) async {
  final e = env ?? Platform.environment;
  final src = locateAndroidServerSources();
  if (src == null) throw AndroidServerError('this glint install has no Android server sources to build from');
  final adb = adbPath == null ? null : File(adbPath);
  final sdk = [
    e['ANDROID_HOME'],
    e['ANDROID_SDK_ROOT'],
    if (adb != null && adb.isAbsolute) adb.parent.parent.path,
    '${e['HOME']}/Library/Android/sdk',
    '${e['HOME']}/Android/Sdk',
  ].whereType<String>().where((p) => Directory('$p/platforms').existsSync()).firstOrNull;
  if (sdk == null) throw AndroidServerError('found no Android SDK with platforms to build the server against');
  String? newest(String dir, String file) {
    final hits = Directory(dir).existsSync()
        ? [
            for (final d in Directory(dir).listSync().whereType<Directory>())
              if (File('${d.path}/$file').existsSync()) '${d.path}/$file'
          ]
        : <String>[];
    int version(String p) =>
        int.tryParse(RegExp(r'(\d+)').firstMatch(p.split('/').reversed.elementAt(1))?.group(1) ?? '') ?? 0;
    hits.sort((a, b) => version(a).compareTo(version(b)));
    return hits.lastOrNull;
  }

  final jar = newest('$sdk/platforms', 'android.jar');
  final d8 = newest('$sdk/build-tools', 'd8');
  if (jar == null || d8 == null) {
    throw AndroidServerError(
        'the Android SDK at $sdk lacks ${jar == null ? 'a platform android.jar' : 'build-tools d8'}');
  }
  final javac = e['JAVA_HOME'] != null && File('${e['JAVA_HOME']}/bin/javac').existsSync()
      ? '${e['JAVA_HOME']}/bin/javac'
      : 'javac';
  final work = await Directory.systemTemp.createTemp('glint-android-server');
  try {
    final sources = [
      for (final f in src.listSync(recursive: true))
        if (f.path.endsWith('.java')) f.path
    ];
    final classes = Directory('${work.path}/classes')..createSync();
    final compiled = await Process.run(javac, ['--release', '11', '-cp', jar, '-d', classes.path, ...sources]);
    if (compiled.exitCode != 0) {
      throw AndroidServerError('javac failed: ${'${compiled.stderr}'.trim().split('\n').take(3).join(' ')}');
    }
    final classFiles = [
      for (final f in classes.listSync(recursive: true))
        if (f.path.endsWith('.class')) f.path
    ];
    final dexed = await Process.run(d8, ['--min-api', '26', '--lib', jar, '--output', work.path, ...classFiles]);
    if (dexed.exitCode != 0) {
      throw AndroidServerError('d8 failed: ${'${dexed.stderr}'.trim().split('\n').take(3).join(' ')}');
    }
    File(dest).parent.createSync(recursive: true);
    File('${work.path}/classes.dex').copySync(dest);
    return dest;
  } on ProcessException catch (err) {
    throw AndroidServerError('could not run the Android build tools: ${err.message}');
  } finally {
    work.deleteSync(recursive: true);
  }
}
