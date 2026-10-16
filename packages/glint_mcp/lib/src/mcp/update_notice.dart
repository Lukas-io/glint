import 'dart:io';

import 'package:glint_core/glint_core.dart';

import '../version.dart';

File get _cache => File('${Platform.environment['HOME'] ?? '.'}/.glint/update-check.json');

/// `GLINT_NO_UPDATE_CHECK=true` stops glint asking pub.dev for its latest version.
bool get _enabled => Platform.environment['GLINT_NO_UPDATE_CHECK']?.toLowerCase() != 'true';

/// Asks pub.dev for glint_mcp's latest version, at most once a day.
Future<void> refreshUpdateCheck() async {
  if (_enabled) await latestPubVersion('glint_mcp', cacheFile: _cache);
}

/// The line attach shows when the last check found a newer glint on pub.dev; null when up to date or unknown.
String? updateNotice() {
  if (!_enabled) return null;
  final latest = cachedPubVersion(_cache);
  if (latest == null || !isNewerVersion(latest, glintVersion)) return null;
  return 'glint $latest is out (this is $glintVersion): tell the user to run `dart pub global activate glint_mcp`, '
      'then restart the MCP server';
}
