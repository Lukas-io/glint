import 'dart:io';

import 'package:glint_core/glint_core.dart';

import '../version.dart';
import 'bounded_process.dart';

/// One file or directory the prune removes, or would.
class PruneItem {
  const PruneItem(this.path, this.bytes, this.reason);
  final String path;
  final int bytes;
  final String reason;
}

/// What a prune removed, or would remove on a dry run.
class PruneReport {
  const PruneReport(this.items, {required this.dryRun});
  final List<PruneItem> items;
  final bool dryRun;

  int get bytes => items.fold(0, (a, i) => a + i.bytes);

  String get summary => items.isEmpty
      ? 'nothing to prune'
      : '${dryRun ? 'would remove' : 'removed'} ${items.length} old item(s), ${(bytes / 1048576).toStringAsFixed(1)} MB';
}

/// Seconds between automatic prunes.
const Duration kPruneEvery = Duration(days: 1);

/// How long a helper must sit unused before another glint version's copy may be pruned.
const Duration kPruneGrace = Duration(days: 7);

final Map<String, DateTime> _marked = {};

/// Notes that [path] was just used, so a prune from another glint version leaves it alone; throttled to once an hour per path.
String markHelperUsed(String path) {
  final now = DateTime.now();
  final last = _marked[path];
  if (last != null && now.difference(last) < const Duration(hours: 1)) return path;
  _marked[path] = now;
  try {
    File(path).setLastModifiedSync(now);
  } on Object {
    return path;
  }
  return path;
}

final _semver = RegExp(r'-(\d+\.\d+\.\d+)(\.dex)?$');

/// Removes helper binaries of other glint versions from `~/.glint/bin` and runner builds of Xcode versions that are gone from `~/.glint/xctest`, at most once a day unless [force]; nothing a live process runs, or any helper used in the last [kPruneGrace], is touched.
Future<PruneReport> pruneCaches({bool dryRun = false, bool force = false, String? home, String? version}) async {
  final root = '${home ?? Platform.environment['HOME'] ?? '.'}/.glint';
  final stamp = File('$root/.pruned');
  if (!force && !dryRun && stamp.existsSync()) {
    final age = DateTime.now().difference(stamp.lastModifiedSync());
    if (age < kPruneEvery) return const PruneReport([], dryRun: false);
  }
  final table = await ProcessTable.read();
  final running = table.rows.map((r) => r.command).toList();
  bool inUse(String path) => running.any((c) => c.contains(path));
  final items = [
    ..._oldHelpers('$root/bin', version ?? glintVersion, inUse),
    ...await _goneRunnerBuilds('$root/xctest', inUse),
  ];
  if (!dryRun) {
    for (final item in items) {
      try {
        final type = FileSystemEntity.typeSync(item.path);
        if (type == FileSystemEntityType.directory) {
          Directory(item.path).deleteSync(recursive: true);
        } else if (type != FileSystemEntityType.notFound) {
          File(item.path).deleteSync();
        }
      } on Object {
        continue;
      }
    }
    try {
      Directory(root).createSync(recursive: true);
      stamp.writeAsStringSync('${DateTime.now().toIso8601String()}\n');
    } on Object {
      return PruneReport(items, dryRun: dryRun);
    }
  }
  return PruneReport(items, dryRun: dryRun);
}

List<PruneItem> _oldHelpers(String binDir, String version, bool Function(String) inUse) {
  final dir = Directory(binDir);
  if (!dir.existsSync()) return const [];
  final files = dir.listSync().whereType<File>().where((f) => f.uri.pathSegments.last.startsWith('glint-')).toList();
  final newestOfHashed = <String, File>{};
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (_semver.hasMatch(name)) continue;
    final family = name.substring(0, name.lastIndexOf('-'));
    final best = newestOfHashed[family];
    if (best == null || f.lastModifiedSync().isAfter(best.lastModifiedSync())) newestOfHashed[family] = f;
  }
  final out = <PruneItem>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final m = _semver.firstMatch(name);
    final String? reason;
    if (m != null) {
      reason = m.group(1) == version ? null : 'helper of glint ${m.group(1)}, this is $version';
    } else {
      final family = name.substring(0, name.lastIndexOf('-'));
      reason = identical(newestOfHashed[family], f) ? null : 'an older build of $family';
    }
    if (reason == null || inUse(f.path) || DateTime.now().difference(f.lastModifiedSync()) < kPruneGrace) continue;
    out.add(PruneItem(f.path, f.lengthSync(), reason));
  }
  return out;
}

Future<List<PruneItem>> _goneRunnerBuilds(String xctestDir, bool Function(String) inUse) async {
  final dir = Directory(xctestDir);
  if (!dir.existsSync()) return const [];
  final installed = await installedXcodeVersions();
  if (installed.isEmpty) return const [];
  final out = <PruneItem>[];
  for (final d in dir.listSync().whereType<Directory>()) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!name.startsWith('xcode-') || name == 'xcode-unknown') continue;
    if (installed.contains(name.substring('xcode-'.length)) || inUse(d.path)) continue;
    out.add(PruneItem(d.path, _size(d), 'Xcode ${name.substring('xcode-'.length)} is no longer installed'));
  }
  return out;
}

int _size(Directory d) {
  var total = 0;
  try {
    for (final e in d.listSync(recursive: true, followLinks: false).whereType<File>()) {
      total += e.lengthSync();
    }
  } on Object {
    return total;
  }
  return total;
}

/// The versions of every Xcode on this Mac: the selected one and each `Xcode*.app` in the Applications folders.
Future<Set<String>> installedXcodeVersions() async {
  final home = Platform.environment['HOME'] ?? '.';
  final plists = <String>{};
  for (final apps in ['/Applications', '$home/Applications']) {
    final d = Directory(apps);
    if (!d.existsSync()) continue;
    for (final app in d.listSync().whereType<Directory>().where((a) => a.path.contains('/Xcode'))) {
      plists.add('${app.path}/Contents/version.plist');
    }
  }
  try {
    final selected =
        await runBounded('xcode-select', ['-p'], timeout: const Duration(seconds: 5), phase: 'xcode-select');
    final dir = '${selected.stdout}'.trim();
    if (dir.endsWith('/Developer')) plists.add('${dir.substring(0, dir.length - '/Developer'.length)}/version.plist');
  } on Object {
    return const {};
  }
  final versions = <String>{};
  for (final p in plists.where((p) => File(p).existsSync())) {
    try {
      final r = await runBounded('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', p],
          timeout: const Duration(seconds: 5), phase: 'plutil reading an Xcode version');
      final v = '${r.stdout}'.trim();
      if (r.exitCode == 0 && v.isNotEmpty) versions.add(v);
    } on Object {
      continue;
    }
  }
  return versions;
}
