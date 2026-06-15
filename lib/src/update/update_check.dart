import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// Background "is there a newer version?" probe that runs at most once per
/// UTC day. Hits the raw `pubspec.yaml` on `main` (no GitHub API, no
/// rate-limit headaches) and parses the `version:` line. When the upstream
/// version is newer, prints one stderr nudge:
///
/// ```
/// glint: v0.0.2 available (you're on 0.0.1). Run `glint update` to
/// upgrade. (Silence with GLINT_NO_UPDATE_CHECK=true.)
/// ```
///
/// All network errors are swallowed silently. Best-effort; never blocks
/// startup, never crashes the MCP, never delays the JSON-RPC handshake.
/// Fire-and-forget from `main()` after the server starts.
class UpdateCheck {
  static const String pubspecUrl =
      'https://raw.githubusercontent.com/Lukas-io/glint/main/pubspec.yaml';
  static const String statusFileName = '.update-status.json';
  static const String cacheFileName = '.update-check';

  static const Duration _connectTimeout = Duration(seconds: 3);
  static const Duration _totalTimeout = Duration(seconds: 5);

  /// Fire-and-forget. Caller MUST NOT await this in a path that blocks
  /// startup; use `unawaited(UpdateCheck.maybeCheck(...))`.
  static Future<void> maybeCheck({
    required String currentVersion,
    required String dataDir,
  }) async {
    try {
      final env = io.Platform.environment;
      if (env['GLINT_NO_UPDATE_CHECK']?.toLowerCase() == 'true') return;

      final cacheFile = io.File(p.join(dataDir, cacheFileName));
      if (_alreadyCheckedToday(cacheFile)) return;

      final upstream = await _fetchUpstreamVersion();
      if (upstream == null) return;

      _touchCache(cacheFile);

      final isNewer = _isNewer(upstream, currentVersion);

      // Agent-readable status file: the telemetry `status` op reads this
      // and surfaces `updateAvailable` so the agent doesn't have to scrape
      // stderr for the nudge.
      writeStatusFile(
        dataDir: dataDir,
        currentVersion: currentVersion,
        latestVersion: upstream,
        isNewer: isNewer,
      );

      if (isNewer) {
        io.stderr.writeln(
          'glint: v$upstream available (you\'re on v$currentVersion). Run '
          '`glint update` to upgrade. (Silence with '
          'GLINT_NO_UPDATE_CHECK=true.)',
        );
      }
    } catch (_) {
      // Best-effort: network / parse / filesystem failures stay silent.
    }
  }

  static bool _alreadyCheckedToday(io.File cacheFile) {
    try {
      if (!cacheFile.existsSync()) return false;
      final raw = cacheFile.readAsStringSync().trim();
      final last = DateTime.tryParse(raw);
      if (last == null) return false;
      final now = DateTime.now().toUtc();
      return last.year == now.year &&
          last.month == now.month &&
          last.day == now.day;
    } catch (_) {
      return false;
    }
  }

  static void _touchCache(io.File cacheFile) {
    try {
      final parent = cacheFile.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    } catch (_) {/* silent */}
  }

  /// Visible for testing: write a status payload to `<dataDir>/[statusFileName]`.
  static void writeStatusFile({
    required String dataDir,
    required String currentVersion,
    required String latestVersion,
    required bool isNewer,
  }) {
    try {
      final file = io.File(p.join(dataDir, statusFileName));
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        'checkedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
        'current': currentVersion,
        'latest': latestVersion,
        'isNewer': isNewer,
        'upgradeCommand': 'glint update',
      }));
    } catch (_) {/* silent */}
  }

  /// Best-effort reader for `telemetry status`. Returns null when the file
  /// is missing / unreadable / malformed.
  static Map<String, Object?>? readStatusFile(String dataDir) {
    try {
      final file = io.File(p.join(dataDir, statusFileName));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _fetchUpstreamVersion() async {
    final client = io.HttpClient()
      ..connectionTimeout = _connectTimeout
      ..userAgent = 'glint-update-check';
    try {
      final request =
          await client.getUrl(Uri.parse(pubspecUrl)).timeout(_connectTimeout);
      final response = await request.close().timeout(_totalTimeout);
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_totalTimeout);
      return parseVersionLine(body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Visible for testing: extracts `0.0.2` from a pubspec containing
  /// `version: 0.0.2`. Returns null when no version line is present or
  /// the value isn't a recognized semver triple.
  static String? parseVersionLine(String yaml) {
    for (final line in const LineSplitter().convert(yaml)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('version:')) continue;
      final value = trimmed.substring('version:'.length).trim();
      final cleaned = value.replaceAll(RegExp('["\']'), '');
      if (_parseTriple(cleaned) != null) return cleaned;
      return null;
    }
    return null;
  }

  /// Visible for testing: true when [upstream] is strictly newer than
  /// [current]. Non-parseable inputs return false (treat as "not newer").
  static bool isNewer(String upstream, String current) =>
      _isNewer(upstream, current);

  static bool _isNewer(String upstream, String current) {
    final u = _parseTriple(upstream);
    final c = _parseTriple(current);
    if (u == null || c == null) return false;
    for (var i = 0; i < 3; i++) {
      if (u[i] > c[i]) return true;
      if (u[i] < c[i]) return false;
    }
    return false;
  }

  /// Parses `0.0.2` into `[0, 0, 2]`. Tolerates a `-prerelease` suffix
  /// (strips it). Returns null on malformed input.
  static List<int>? _parseTriple(String version) {
    final base = version.split('-').first;
    final parts = base.split('.');
    if (parts.length != 3) return null;
    final out = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }
}
