import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// Single source of truth for the running package version. Read by
/// `lib/src/observability/telemetry/usage_reporter.dart`,
/// `bin/glint.dart` (UpdateCheck), and the crash payload. Must match
/// the `version:` line in `pubspec.yaml` — bump in both places.
const String packageVersion = '0.0.1';

/// Commit SHA baked in at AOT-compile time by `glint install` via
/// `-Dglint_sha=<sha>`. Empty when running JIT (the wrapper that ships
/// from `dart pub global activate`).
const String _bakedSha = String.fromEnvironment('glint_sha');

String? _cachedRuntimeSha;
bool _runtimeShaResolved = false;

/// Git commit SHA the running binary was built from. Sources, in order:
/// (1) baked-in `-D` constant set by `install`, (2) `git rev-parse HEAD`
/// against the activated source dir (works under JIT). Cached per
/// process. Returns null on best-effort failure.
String? currentCommitSha() {
  if (_bakedSha.isNotEmpty) return _bakedSha;
  if (_runtimeShaResolved) return _cachedRuntimeSha;
  _runtimeShaResolved = true;
  _cachedRuntimeSha = _readGitHead();
  return _cachedRuntimeSha;
}

/// 12-char prefix of [currentCommitSha], or null when the SHA is unknown.
String? shortCommit() {
  final full = currentCommitSha();
  if (full == null || full.length < 12) return full;
  return full.substring(0, 12);
}

/// True when running an AOT-compiled native binary (the result of
/// `glint install`). False under the JIT snapshot wrapper.
const bool isAotBuild = bool.fromEnvironment('dart.vm.product');

String? _readGitHead() {
  try {
    final script = io.Platform.script.toFilePath();
    if (!script.endsWith('.dart')) return null;
    final sourceDir = p.dirname(p.dirname(script));
    final result = io.Process.runSync(
      'git',
      ['-C', sourceDir, 'rev-parse', 'HEAD'],
    );
    if (result.exitCode != 0) return null;
    final raw = (result.stdout as String?) ?? '';
    final sha = raw.trim();
    return sha.isEmpty ? null : sha;
  } catch (_) {
    return null;
  }
}
