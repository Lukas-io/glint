import 'package:glint_mcp/src/perception/geometry.dart';
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
        expect(expr, contains('"$key":'), reason: 'missing key "$key" in geometry expression');
      }
    });

    test('uses widget-tree hittability check (AbsorbPointer / IgnorePointer)', () {
      final expr = GeometryExpr.build();
      expect(expr, contains('AbsorbPointer'));
      expect(expr, contains('IgnorePointer'));
    });

    test('op multiplies every painted opacity up the render chain, not just the nearest Opacity widget', () {
      final expr = GeometryExpr.build();
      for (final type in [
        'RenderOpacity',
        'RenderAnimatedOpacity',
        'RenderSliverOpacity',
        'RenderSliverAnimatedOpacity'
      ]) {
        expect(expr, contains("'$type'"));
      }
      expect(expr, contains('o = o * r.opacity.value'), reason: 'AnimatedOpacity / FadeTransition paint an Animation');
      expect(expr, contains('r = r.parent'));
      expect(expr, isNot(contains('findAncestorWidgetOfExactType<Opacity>')));
    });

    test('stays a single line for evaluate', () {
      expect(GeometryExpr.build(), isNot(contains('\n')));
      expect(GeometryExpr.opacityOf, isNot(contains('\n')));
    });

    test('binds center via Offset-only lambda (no HitTestResult lambda param)', () {
      final expr = GeometryExpr.build();
      expect(expr, contains('(Offset c)'));
      expect(expr, isNot(contains('HitTestResult r')));
    });
  });

  group('GeometryExpr.buildImplicitViewProbe()', () {
    test('needs no inspector selection and carries dpr/vw/vh', () {
      final expr = GeometryExpr.buildImplicitViewProbe();
      expect(expr, isNot(contains('selection')));
      expect(expr, contains('implicitView'));
      for (final key in ['dpr', 'vw', 'vh']) {
        expect(expr, contains('"$key":'));
      }
    });
  });
}
