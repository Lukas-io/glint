import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('redactPath', () {
    test('empty input passes through', () {
      expect(redactPath(''), '');
    });

    test('package: URIs untouched (already safe)', () {
      const input =
          '#0 SceneReader.readSummary (package:glint/src/perception/scene_reader.dart:42)';
      expect(redactPath(input), input);
    });

    test('POSIX StudioProjects path collapses to <project:X>', () {
      const input = '/Users/lukasio/StudioProjects/sanga_mobile/lib/main.dart';
      expect(redactPath(input), '<project:sanga_mobile>/lib/main.dart');
    });

    test('POSIX generic homedir collapses to <home>', () {
      const input = '/Users/lukasio/code/app/lib/main.dart';
      expect(redactPath(input), '<home>/code/app/lib/main.dart');
    });

    test('different usernames produce same redaction', () {
      const a = '/Users/alice/StudioProjects/sanga_mobile/lib/main.dart';
      const b = '/Users/bob/StudioProjects/sanga_mobile/lib/main.dart';
      expect(redactPath(a), redactPath(b));
    });

    test('Windows StudioProjects path collapses', () {
      const input =
          r'C:\Users\lukasio\StudioProjects\sanga_mobile\lib\main.dart';
      expect(redactPath(input), r'<project:sanga_mobile>\lib\main.dart');
    });

    test('Windows generic homedir collapses', () {
      const input = r'C:\Users\lukasio\code\app\lib\main.dart';
      expect(redactPath(input), r'<home>\code\app\lib\main.dart');
    });

    test('idempotent — running twice produces same output', () {
      const input = '/Users/lukasio/StudioProjects/x/lib/main.dart';
      final once = redactPath(input);
      final twice = redactPath(once);
      expect(once, twice);
    });

    test('paths without homedir patterns untouched', () {
      const input = '#0 main (file:///some/system/path/dart.dart:1:1)';
      expect(redactPath(input), input);
    });
  });

  group('redactStackHead', () {
    test('empty trace returns empty list', () {
      expect(redactStackHead(StackTrace.empty), isEmpty);
    });

    test('caps at maxFrames', () {
      final lines = [
        for (var i = 0; i < 20; i++)
          '#$i frameAt$i (package:foo/bar.dart:$i:5)',
      ].join('\n');
      final stack = StackTrace.fromString(lines);
      final out = redactStackHead(stack, maxFrames: 5);
      expect(out, hasLength(5));
      expect(out.first, startsWith('#0 frameAt0'));
      expect(out.last, startsWith('#4 frameAt4'));
    });

    test('redacts homedir paths in each frame', () {
      final stack = StackTrace.fromString(
        '#0 main (/Users/lukasio/StudioProjects/x/lib/main.dart:1:1)\n'
        '#1 _other (/Users/lukasio/code/app/lib/util.dart:5:10)',
      );
      final out = redactStackHead(stack);
      expect(out[0], contains('<project:x>/lib/main.dart'));
      expect(out[1], contains('<home>/code/app/lib/util.dart'));
      expect(out.any((s) => s.contains('lukasio')), isFalse);
    });
  });
}
