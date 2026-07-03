import 'package:glint/glint.dart';
import 'package:glint/src/mcp/tool_args.dart';
import 'package:test/test.dart';

enum _Dir { up, down }

void main() {
  group('enumByName', () {
    test('matches by name, null on miss or null input', () {
      expect(enumByName(_Dir.values, 'down'), _Dir.down);
      expect(enumByName(_Dir.values, 'sideways'), isNull);
      expect(enumByName(_Dir.values, null), isNull);
    });
  });

  group('readPoint', () {
    test('reads x,y as doubles from ints or nums', () {
      final p = readPoint(const {'x': 10, 'y': 20.5});
      expect(p, isNotNull);
      expect(p!.x, 10.0);
      expect(p.y, 20.5);
    });

    test('null when either coordinate is absent', () {
      expect(readPoint(const {'x': 10}), isNull);
      expect(readPoint(const {'y': 20}), isNull);
      expect(readPoint(const {}), isNull);
    });
  });

  group('readSegment', () {
    test('reads all four corners', () {
      final s = readSegment(const {'x1': 1, 'y1': 2, 'x2': 3, 'y2': 4});
      expect(s, isNotNull);
      expect([s!.x1, s.y1, s.x2, s.y2], [1.0, 2.0, 3.0, 4.0]);
    });

    test('null when any corner is missing', () {
      expect(readSegment(const {'x1': 1, 'y1': 2, 'x2': 3}), isNull);
    });
  });

  group('readTargetedArgs', () {
    test('applies defaults from config when args are absent', () {
      final t = readTargetedArgs(const {}, GlintConfig(readyTimeoutMs: 7000));
      expect(t.awaitReady, isFalse);
      expect(t.readyTimeoutMs, 7000);
      expect(t.returnScene, isTrue);
      expect(t.fetchScene, isFalse);
      expect(t.detail, isFalse);
    });

    test('reads provided values, overriding the config default', () {
      final t = readTargetedArgs(const {
        'awaitReady': true,
        'readyTimeoutMs': 250,
        'returnScene': false,
        'fetchScene': true,
        'detail': true,
      }, GlintConfig());
      expect(t.awaitReady, isTrue);
      expect(t.readyTimeoutMs, 250);
      expect(t.returnScene, isFalse);
      expect(t.fetchScene, isTrue);
      expect(t.detail, isTrue);
    });
  });
}
