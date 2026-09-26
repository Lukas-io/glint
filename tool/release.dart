import 'dart:io';

/// Release helper for one package: `prepare <package> <x.y.z>` bumps it on release/<package>-v<x.y.z>, `tag <package>` tags the merged release, `notes <package> <x.y.z>` prints its changelog section.
const defaultBranch = 'main';

/// The shared package; a package that depends on it is released only after it.
const corePackage = 'glint_core';

/// Per package, the files holding its version (relative to the package) and the pattern whose first group is the version.
final packageVersionFiles = <String, Map<String, RegExp>>{
  'glint_network': {
    'pubspec.yaml': _pubspecVersion,
    'lib/src/version.dart': RegExp(r"^const String packageVersion = '([^']+)';$", multiLine: true),
  },
  'glint_mcp': {
    'pubspec.yaml': _pubspecVersion,
    'lib/src/version.dart': RegExp(r"^const String glintVersion = '([^']+)';$", multiLine: true),
  },
};

final _pubspecVersion = RegExp(r'^version: (\S+)$', multiLine: true);

const _usage = 'usage: prepare <package> <x.y.z> | tag <package> | notes <package> <x.y.z>\n'
    'packages: ';

Future<void> main(List<String> args) async {
  final usage = '$_usage${packageVersionFiles.keys.join(', ')}';
  if (args.length < 2 || !packageVersionFiles.containsKey(args[1])) _fail(usage);
  final package = args[1];
  switch (args.first) {
    case 'prepare' when args.length == 3:
      await _prepare(package, args[2]);
    case 'tag' when args.length == 2:
      await _tag(package);
    case 'notes' when args.length == 3:
      stdout.write(changelogSection(_changelog(package).readAsStringSync(), args[2]) ??
          _fail('$package CHANGELOG.md has no section for ${args[2]}'));
    default:
      _fail(usage);
  }
}

/// The git tag of [package] at [version].
String releaseTag(String package, String version) => '$package-v$version';

String packageDir(String package) => 'packages/$package';

File _changelog(String package) => File('${packageDir(package)}/CHANGELOG.md');

Future<void> _prepare(String package, String version) async {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) _fail('version must look like 1.2.3');
  await _requireCleanDefaultBranch();
  final blocker = coreBlocker(package);
  if (blocker != null) _fail(blocker);
  final current = currentVersion(package);
  if (!isNewer(version, current)) _fail('$version is not newer than $current');
  final changelog = _changelog(package);
  final dated = datedChangelog(changelog.readAsStringSync(), version, DateTime.now());
  if (dated == null) _fail('${changelog.path} has no entries under ## [Unreleased]');
  final tag = releaseTag(package, version);
  await _git(['checkout', '-b', 'release/$tag']);
  final files = packageVersionFiles[package]!;
  for (final entry in files.entries) {
    final file = File('${packageDir(package)}/${entry.key}');
    file.writeAsStringSync(file.readAsStringSync().replaceFirstMapped(
        entry.value, (m) => m[0]!.replaceFirst(m[1]!, version)));
  }
  changelog.writeAsStringSync(dated);
  await _git(['add', changelog.path, for (final f in files.keys) '${packageDir(package)}/$f']);
  await _git(['commit', '-m', 'Release $package $version']);
  stdout.writeln('Committed "Release $package $version" on release/$tag. Open a PR; after it merges, run: '
      'dart run tool/release.dart tag $package');
}

Future<void> _tag(String package) async {
  await _requireCleanDefaultBranch();
  final version = currentVersion(package);
  if (changelogSection(_changelog(package).readAsStringSync(), version) == null) {
    _fail('$package CHANGELOG.md has no section for $version; run prepare first');
  }
  final tag = releaseTag(package, version);
  final existing = await Process.run('git', ['tag', '--list', tag]);
  if ((existing.stdout as String).trim().isNotEmpty) _fail('tag $tag already exists');
  await _git(['tag', '-a', tag, '-m', 'Release $package $version']);
  await _git(['push', 'origin', tag]);
  stdout.writeln('Pushed $tag; the release workflow publishes the GitHub Release.');
}

/// Why [package] cannot be released yet: it depends on [corePackage] while core has unreleased changes.
String? coreBlocker(String package, {String root = '.'}) {
  if (package == corePackage) return null;
  final pubspec = File('$root/${packageDir(package)}/pubspec.yaml').readAsStringSync();
  if (!RegExp('^  $corePackage:', multiLine: true).hasMatch(pubspec)) return null;
  final coreLog = File('$root/${packageDir(corePackage)}/CHANGELOG.md');
  if (!coreLog.existsSync()) return null;
  final unreleased = datedChangelog(coreLog.readAsStringSync(), '0.0.0', DateTime(2000));
  return unreleased == null
      ? null
      : '$corePackage has unreleased changes; release $corePackage first, then bump the '
          'constraint in $package';
}

/// The version every version file of [package] agrees on.
String currentVersion(String package, {String root = '.'}) {
  final found = {
    for (final entry in packageVersionFiles[package]!.entries)
      entry.key: entry.value
          .firstMatch(File('$root/${packageDir(package)}/${entry.key}').readAsStringSync())?[1],
  };
  final distinct = found.values.toSet();
  if (distinct.length != 1 || distinct.first == null) _fail('$package version files disagree: $found');
  return distinct.first!;
}

/// True when [a] is a higher semver triple than [b].
bool isNewer(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}

/// The changelog with the Unreleased entries moved under a dated heading for [version], and an empty Unreleased above it; null when there is nothing unreleased.
String? datedChangelog(String text, String version, DateTime date) {
  final header = RegExp(r'^## \[Unreleased\]\s*$', multiLine: true).firstMatch(text);
  if (header == null) return null;
  final next = RegExp(r'^## \[', multiLine: true).firstMatch(text.substring(header.end));
  final body = next == null ? text.substring(header.end) : text.substring(header.end, header.end + next.start);
  if (body.trim().isEmpty) return null;
  final day = date.toIso8601String().substring(0, 10);
  return '${text.substring(0, header.start)}## [Unreleased]\n\n## [$version] - $day\n'
      '${text.substring(header.end)}';
}

/// The body of the `## [version]` section, without its heading; null when there is none.
String? changelogSection(String text, String version) {
  final header = RegExp('^## \\[${RegExp.escape(version)}\\].*\$', multiLine: true).firstMatch(text);
  if (header == null) return null;
  final rest = text.substring(header.end);
  final next = RegExp(r'^## \[', multiLine: true).firstMatch(rest);
  final body = (next == null ? rest : rest.substring(0, next.start)).trim();
  return body.isEmpty ? null : '$body\n';
}

Future<void> _requireCleanDefaultBranch() async {
  final branch = (await Process.run('git', ['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.toString().trim();
  if (branch != defaultBranch) _fail('run this on $defaultBranch (on $branch)');
  final status = (await Process.run('git', ['status', '--porcelain', '--untracked-files=no'])).stdout.toString();
  if (status.trim().isNotEmpty) _fail('commit or stash your changes first');
  await _git(['pull', '--ff-only']);
}

Future<void> _git(List<String> args) async {
  final r = await Process.run('git', args);
  if (r.exitCode != 0) _fail('git ${args.join(' ')} failed: ${r.stderr}');
}

Never _fail(String message) {
  stderr.writeln('release: $message');
  exit(1);
}
