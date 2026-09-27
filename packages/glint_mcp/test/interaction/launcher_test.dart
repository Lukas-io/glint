import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:test/test.dart';

void main() {
  group('flutterAppProblem', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('glint-launch'));
    tearDown(() => dir.deleteSync(recursive: true));

    void pubspec(String deps) => File('${dir.path}/pubspec.yaml').writeAsStringSync('name: x\n$deps');

    test('a Flutter app with lib/main.dart passes', () {
      pubspec('dependencies:\n  flutter:\n    sdk: flutter\n');
      File('${dir.path}/lib/main.dart').createSync(recursive: true);
      expect(flutterAppProblem(dir.path), isNull);
    });

    test('a folder without pubspec.yaml is refused', () {
      expect(flutterAppProblem(dir.path), contains('no pubspec.yaml'));
    });

    test('a Dart package or the Flutter SDK root is refused', () {
      pubspec('workspace:\n  - packages/flutter\n');
      expect(flutterAppProblem(dir.path), contains('does not depend on the flutter SDK'));
    });

    test('a Flutter package without lib/main.dart is refused', () {
      pubspec('dependencies:\n  flutter:\n    sdk: flutter\n');
      expect(flutterAppProblem(dir.path), contains('no lib/main.dart'));
    });
  });
}
