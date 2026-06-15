import 'dart:convert';
import 'dart:io';

import 'package:glint/src/update/update_check.dart';
import 'package:test/test.dart';

void main() {
  group('UpdateCheck.parseVersionLine', () {
    test('extracts a clean semver triple', () {
      const yaml = '''
name: glint
description: hi
version: 0.0.2
environment:
  sdk: ^3.5.0
''';
      expect(UpdateCheck.parseVersionLine(yaml), '0.0.2');
    });

    test('strips surrounding quotes', () {
      const yaml = "version: '0.7.3'";
      expect(UpdateCheck.parseVersionLine(yaml), '0.7.3');
    });

    test('returns null when no version line is present', () {
      expect(UpdateCheck.parseVersionLine('name: glint\n'), null);
    });

    test('returns null on a non-triple version', () {
      expect(UpdateCheck.parseVersionLine('version: hotfix\n'), null);
    });

    test('tolerates a prerelease suffix (strips it for parsing)', () {
      const yaml = 'version: 0.8.0-beta.1';
      expect(UpdateCheck.parseVersionLine(yaml), '0.8.0-beta.1');
    });
  });

  group('UpdateCheck.isNewer', () {
    test('larger patch is newer', () {
      expect(UpdateCheck.isNewer('0.0.2', '0.0.1'), isTrue);
    });

    test('larger minor is newer than smaller minor regardless of patch', () {
      expect(UpdateCheck.isNewer('0.1.0', '0.0.99'), isTrue);
    });

    test('larger major is newer regardless of minor/patch', () {
      expect(UpdateCheck.isNewer('1.0.0', '0.99.99'), isTrue);
    });

    test('equal versions are NOT newer', () {
      expect(UpdateCheck.isNewer('0.0.1', '0.0.1'), isFalse);
    });

    test('older upstream is not newer', () {
      expect(UpdateCheck.isNewer('0.0.1', '0.0.2'), isFalse);
    });

    test('non-parseable inputs return false (treat as not-newer)', () {
      expect(UpdateCheck.isNewer('hotfix', '0.0.1'), isFalse);
      expect(UpdateCheck.isNewer('0.0.2', 'unknown'), isFalse);
    });
  });

  group('UpdateCheck.writeStatusFile / readStatusFile', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('glint-update-test-');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round-trips a payload with the expected fields', () {
      UpdateCheck.writeStatusFile(
        dataDir: tmp.path,
        currentVersion: '0.0.1',
        latestVersion: '0.0.2',
        isNewer: true,
      );
      final read = UpdateCheck.readStatusFile(tmp.path);
      expect(read, isNotNull);
      expect(read!['current'], '0.0.1');
      expect(read['latest'], '0.0.2');
      expect(read['isNewer'], true);
      expect(read['upgradeCommand'], 'glint update');
      expect(read['checkedAtMs'], isA<int>());
    });

    test('reads null when the file does not exist', () {
      expect(UpdateCheck.readStatusFile(tmp.path), null);
    });

    test('reads null on malformed content', () {
      File('${tmp.path}/${UpdateCheck.statusFileName}')
          .writeAsStringSync('{garbage');
      expect(UpdateCheck.readStatusFile(tmp.path), null);
    });

    test('isNewer=false is preserved', () {
      UpdateCheck.writeStatusFile(
        dataDir: tmp.path,
        currentVersion: '0.0.2',
        latestVersion: '0.0.2',
        isNewer: false,
      );
      final read = UpdateCheck.readStatusFile(tmp.path);
      expect(read!['isNewer'], false);
    });

    test('file is valid JSON', () {
      UpdateCheck.writeStatusFile(
        dataDir: tmp.path,
        currentVersion: '0.0.1',
        latestVersion: '0.0.2',
        isNewer: true,
      );
      final raw = File('${tmp.path}/${UpdateCheck.statusFileName}')
          .readAsStringSync();
      expect(() => jsonDecode(raw), returnsNormally);
    });
  });
}
