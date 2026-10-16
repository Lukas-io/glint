import 'dart:convert';
import 'dart:io';

/// [package]'s latest version on pub.dev, asked at most once a UTC day and cached in [cacheFile]; null when unknown, and it never throws.
Future<String?> latestPubVersion(
  String package, {
  required File cacheFile,
  Duration timeout = const Duration(seconds: 5),
  DateTime? now,
}) async {
  final today = (now ?? DateTime.now()).toUtc();
  final cached = _readCache(cacheFile);
  if (cached != null && _sameDay(cached.checkedAt, today)) return cached.latest;
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = 'glint-update-check';
  try {
    final request = await client.getUrl(Uri.parse('https://pub.dev/api/packages/$package')).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) return cached?.latest;
    final decoded = jsonDecode(await response.transform(utf8.decoder).join().timeout(timeout));
    final latest = decoded is Map && decoded['latest'] is Map ? (decoded['latest'] as Map)['version'] : null;
    if (latest is! String) return cached?.latest;
    cacheFile.parent.createSync(recursive: true);
    cacheFile.writeAsStringSync(jsonEncode({'checkedAt': today.toIso8601String(), 'latest': latest}));
    return latest;
  } on Object {
    return cached?.latest;
  } finally {
    client.close(force: true);
  }
}

/// The version [latestPubVersion] last cached in [cacheFile], however old; null when there is none.
String? cachedPubVersion(File cacheFile) => _readCache(cacheFile)?.latest;

/// Whether [candidate] is a newer `major.minor.patch` than [current]; prerelease suffixes are ignored and anything unparseable is not newer.
bool isNewerVersion(String candidate, String current) {
  final a = _triple(candidate);
  final b = _triple(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

List<int>? _triple(String version) {
  final parts = version.split('-').first.split('.');
  if (parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  return numbers.contains(null) ? null : numbers.cast<int>();
}

({DateTime checkedAt, String latest})? _readCache(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    final checkedAt = DateTime.tryParse('${decoded['checkedAt']}');
    final latest = decoded['latest'];
    return checkedAt == null || latest is! String ? null : (checkedAt: checkedAt.toUtc(), latest: latest);
  } on Object {
    return null;
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
