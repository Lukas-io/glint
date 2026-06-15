import 'package:glint/src/perception/geometry.dart';
import 'package:test/test.dart';

void main() {
  group('GeometryExpr.build()', () {
    test('does not name HitTestResult as a type or constructor', () {
      final expr = GeometryExpr.build();
      expect(expr, isNot(contains('HitTestResult')),
          reason: 'HitTestResult is not accessible in Dart 3.12 synthetic eval '
              'scopes; the expression must not name it');
    });

    test('contains all required JSON keys', () {
      final expr = GeometryExpr.build();
      for (final key in ['gx', 'gy', 'bx', 'by', 'bw', 'bh', 'dpr', 'vw', 'vh', 'op', 'vis', 'hit']) {
        expect(expr, contains('"$key":'),
            reason: 'missing key "$key" in geometry expression');
      }
    });

    test('uses widget-tree hittability check (AbsorbPointer / IgnorePointer)', () {
      final expr = GeometryExpr.build();
      expect(expr, contains('AbsorbPointer'));
      expect(expr, contains('IgnorePointer'));
    });

    test('binds center via Offset-only lambda (no HitTestResult lambda param)', () {
      final expr = GeometryExpr.build();
      expect(expr, contains('(Offset c)'));
      expect(expr, isNot(contains('HitTestResult r')));
    });
  });
}
