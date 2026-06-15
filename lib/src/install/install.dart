import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../observability/telemetry/env.dart';
import '../version.dart';

/// `glint install` subcommand: AOT-compiles this package's entrypoint via
/// `dart compile exe` and writes the resulting native binary over the JIT
/// wrapper that `dart pub global activate` ships.
///
/// Why: the standard `pub global activate -s git URL` install ships a
/// snapshot wrapper that re-runs `pub get` + recompiles on every spawn.
/// Cold start is 1–2 seconds, which the MCP host's JSON-RPC handshake can
/// race and mark the server as "Failed to connect" on first attach. AOT
/// cuts startup to <100ms.
///
/// On success, writes a marker file `<data-dir>/.compiled` so the future
/// `update` subcommand knows the user prefers an AOT binary and should
/// re-compile after each `pub global activate`.
Future<void> runInstall(List<String> args) async {
  final source = _resolveSourcePath();
  if (source == null) {
    io.stderr.writeln(
      'glint install: could not locate the package source. '
      'Platform.script="${io.Platform.script}". Run from inside the '
      'activated glint install, or run `dart pub global activate -s git '
      'https://github.com/Lukas-io/glint.git` first.',
    );
    io.exitCode = 70;
    return;
  }

  final output = _resolveOutputPath();
  if (output == null) {
    io.stderr.writeln(
      'glint install: could not resolve install output path. '
      'Set PUB_CACHE or HOME and retry.',
    );
    io.exitCode = 70;
    return;
  }

  // Bake the git SHA into the binary so `telemetry status` can surface it.
  final sha = currentCommitSha();
  io.stderr.writeln(
    'glint install: compiling $source\n'
    '            to $output\n'
    '${sha != null ? "       commit ${sha.substring(0, 12)}\n" : ""}'
    '(this takes ~10–20s; the resulting binary starts in <100ms).',
  );

  final io.Process compile;
  try {
    compile = await io.Process.start(
      'dart',
      [
        'compile',
        'exe',
        source,
        if (sha != null) '-Dglint_sha=$sha',
        '-o',
        output,
      ],
      mode: io.ProcessStartMode.inheritStdio,
    );
  } on io.ProcessException catch (e) {
    io.stderr.writeln(
      'glint install: failed to spawn `dart` (${e.message}). Is the Dart '
      'SDK on your PATH? Install from https://dart.dev/get-dart, verify '
      'with `which dart`, then retry.',
    );
    io.exitCode = 127;
    return;
  }
  final exitCode = await compile.exitCode;
  if (exitCode != 0) {
    io.stderr.writeln(
      'glint install: dart compile exe exited $exitCode. See the dart '
      'output above. The JIT wrapper at $output is unchanged.',
    );
    io.exitCode = exitCode;
    return;
  }

  _writeCompiledMarker();

  io.stderr.writeln(
    'glint install: done. Restart your MCP host to pick up the native '
    'binary (sub-100ms startup, no more handshake races).',
  );
}

/// Resolves the path to `bin/glint.dart` inside the currently-running
/// install. Under the JIT wrapper, `Platform.script` points at the
/// activated source file directly. Under an already-compiled AOT binary
/// we still want to re-compile from the same source location — derived
/// via the pub-cache structure (`<pub_cache>/git/glint-*/bin/glint.dart`).
String? _resolveSourcePath() {
  final script = io.Platform.script.toFilePath();
  if (script.endsWith('.dart') && io.File(script).existsSync()) {
    return script;
  }

  // Already AOT-compiled — search pub-cache for the activated source.
  final cache = _pubCacheDir();
  if (cache == null) return null;
  final gitDir = io.Directory(p.join(cache, 'git'));
  if (!gitDir.existsSync()) return null;
  io.FileSystemEntity? newest;
  var newestStamp = DateTime.fromMillisecondsSinceEpoch(0);
  for (final entity in gitDir.listSync()) {
    if (entity is! io.Directory) continue;
    if (!p.basename(entity.path).startsWith('glint')) continue;
    final candidate = io.File(p.join(entity.path, 'bin', 'glint.dart'));
    if (!candidate.existsSync()) continue;
    final stamp = candidate.lastModifiedSync();
    if (stamp.isAfter(newestStamp)) {
      newestStamp = stamp;
      newest = candidate;
    }
  }
  return newest?.path;
}

/// Resolves the install target — the path the JIT wrapper currently
/// occupies, which we're about to overwrite with a native binary.
String? _resolveOutputPath() {
  final cache = _pubCacheDir();
  if (cache == null) return null;
  final binName = io.Platform.isWindows ? 'glint.bat' : 'glint';
  return p.join(cache, 'bin', binName);
}

/// `$PUB_CACHE`, falling back to `$HOME/.pub-cache` on POSIX or
/// `$APPDATA/Pub/Cache` on Windows. Matches the dart-sdk default.
String? _pubCacheDir() {
  final env = io.Platform.environment;
  final override = env['PUB_CACHE'];
  if (override != null && override.isNotEmpty) return override;
  if (io.Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return p.join(appData, 'Pub', 'Cache');
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.pub-cache');
}

/// Writes `<data-dir>/.compiled` (one-line ISO timestamp). Used by the
/// `update` subcommand to know the user prefers an AOT binary after the
/// next `pub global activate`. Errors are silent — the marker is a hint,
/// not a hard requirement.
void _writeCompiledMarker() {
  try {
    final dir = resolveDataDir();
    final dirHandle = io.Directory(dir);
    if (!dirHandle.existsSync()) dirHandle.createSync(recursive: true);
    io.File(p.join(dir, '.compiled'))
        .writeAsStringSync(DateTime.now().toUtc().toIso8601String());
  } catch (_) {/* silent — marker is best-effort */}
}

/// True iff the user previously ran `install` (so update should re-compile
/// after re-activating). Used by `glint update`.
bool wantsAotAfterUpdate() {
  try {
    return io.File(p.join(resolveDataDir(), '.compiled')).existsSync();
  } catch (_) {
    return false;
  }
}
