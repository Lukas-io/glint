import 'package:glint/src/mcp/tools/scroll_tool.dart';
import 'package:test/test.dart';

void main() {
  group('ScrollTool.mergeScrollSignal', () {
    test('lazy list: tree changed → contentChanged, movement irrelevant', () {
      final r = ScrollTool.mergeScrollSignal('contentChanged', 0.0);
      expect(r.changed, isTrue);
      expect(r.category, 'contentChanged');
    });

    test('realized scroll: tree nothing but anchor moved → scrolled', () {
      final r = ScrollTool.mergeScrollSignal('nothing', 640.0);
      expect(r.changed, isTrue);
      expect(r.category, 'scrolled');
    });

    test('genuinely stuck: tree nothing and no movement → nothing', () {
      final r = ScrollTool.mergeScrollSignal('nothing', 0.0);
      expect(r.changed, isFalse);
      expect(r.category, 'nothing');
    });

    test('sub-threshold jitter does not count as a scroll', () {
      final r = ScrollTool.mergeScrollSignal('nothing', 1.0);
      expect(r.changed, isFalse);
      expect(r.category, 'nothing');
    });

    test('null movement (anchor gone) falls back to tree category', () {
      expect(ScrollTool.mergeScrollSignal('nothing', null).category, 'nothing');
      expect(ScrollTool.mergeScrollSignal('routeChanged', null).category,
          'routeChanged');
    });

    test('route change is preserved even if the anchor also moved', () {
      final r = ScrollTool.mergeScrollSignal('routeChanged', 640.0);
      expect(r.category, 'routeChanged');
      expect(r.changed, isTrue);
    });
  });
}
