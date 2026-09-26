import 'dart:io';

import 'package:test/test.dart';

import '../release.dart';

void main() {
  test('every package\'s version files agree', () {
    for (final package in packageVersionFiles.keys) {
      final version = currentVersion(package);
      expect(File('packages/$package/pubspec.yaml').readAsStringSync(),
          contains('version: $version'));
    }
  });

  test('tags and release branches carry the package name', () {
    expect(releaseTag('glint_mcp', '0.2.0'), 'glint_mcp-v0.2.0');
  });

  group('coreBlocker', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('release');
      File('${root.path}/packages/app/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: app\ndependencies:\n  glint_core: ^0.1.0\n');
      File('${root.path}/packages/glint_core/CHANGELOG.md').createSync(recursive: true);
    });
    tearDown(() => root.deleteSync(recursive: true));

    void coreLog(String text) =>
        File('${root.path}/packages/glint_core/CHANGELOG.md').writeAsStringSync(text);

    test('refuses a dependent while core has unreleased entries', () {
      coreLog('## [Unreleased]\n\n- New helper.\n\n## [0.1.0] - x\n- Old.\n');
      expect(coreBlocker('app', root: root.path), contains('release glint_core first'));
    });

    test('allows it once core is released', () {
      coreLog('## [Unreleased]\n\n## [0.1.0] - x\n- Old.\n');
      expect(coreBlocker('app', root: root.path), isNull);
    });

    test('ignores packages that do not use core', () {
      coreLog('## [Unreleased]\n\n- New helper.\n');
      File('${root.path}/packages/app/pubspec.yaml').writeAsStringSync('name: app\n');
      expect(coreBlocker('app', root: root.path), isNull);
    });
  });

  const changelog = '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A thing.\n\n## [0.1.0] - 2026-01-01\n\n- Old.\n';

  test('prepare moves Unreleased entries under a dated heading', () {
    final out = datedChangelog(changelog, '0.2.0', DateTime(2026, 9, 25))!;
    expect(out, contains('## [Unreleased]\n\n## [0.2.0] - 2026-09-25\n\n### Fixed\n\n- A thing.'));
    expect(changelogSection(out, '0.2.0'), '### Fixed\n\n- A thing.\n');
    expect(changelogSection(out, '0.1.0'), '- Old.\n');
  });

  test('prepare refuses an empty Unreleased section', () {
    expect(datedChangelog('## [Unreleased]\n\n## [0.1.0] - x\n- Old.\n', '0.2.0', DateTime(2026)), isNull);
  });

  test('versions compare as numbers, not text', () {
    expect(isNewer('0.11.0', '0.10.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.18'), isTrue);
    expect(isNewer('0.10.0', '0.10.0'), isFalse);
  });

  test('the notes command finds sections written with an em dash too', () {
    expect(changelogSection('## [0.10.0] — 2026-07-02\n\n- Shipped.\n', '0.10.0'), '- Shipped.\n');
  });

  test('releasing core raises the glint_core constraint in dependents', () {
    const pubspec = 'name: app\ndependencies:\n  dart_mcp: ^0.5.1\n  glint_core: ^0.0.0\n  path: ^1.9.0\n';
    expect(withCoreConstraint(pubspec, '0.1.0'),
        'name: app\ndependencies:\n  dart_mcp: ^0.5.1\n  glint_core: ^0.1.0\n  path: ^1.9.0\n');
    expect(withCoreConstraint('name: other\n', '0.1.0'), 'name: other\n');
  });
}
