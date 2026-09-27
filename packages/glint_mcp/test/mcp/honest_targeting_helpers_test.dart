import 'package:glint_mcp/perception.dart';
import 'package:glint_mcp/src/mcp/envelope.dart';
import 'package:glint_mcp/src/mcp/tools/scroll_tool.dart';
import 'package:test/test.dart';

SceneNode _n(String label,
        {String? glintId, String? text, List<SceneNode> children = const []}) =>
    SceneNode(
      depth: 1,
      indexInParent: 0,
      description: label,
      type: '_Element',
      inspectorId: 'i-$label',
      widgetRuntimeType: label,
      glintId: glintId,
      textPreview: text,
      children: children,
    );

void main() {
  group('reasonLine', () {
    test('joins a VM header to the line that carries the reason', () {
      expect(
        reasonLine('evaluate(geometry) failed: Unhandled exception:\nBad state: No element\n#0 ...'),
        'evaluate(geometry) failed: Unhandled exception: Bad state: No element',
      );
    });

    test('keeps a one-line detail as it is', () {
      expect(reasonLine('no node with glintId "x"'), 'no node with glintId "x"');
    });

    test('caps very long reasons', () {
      expect(reasonLine('a' * 500).length, 240);
    });
  });

  group('label as id', () {
    final root = _n('Column', glintId: 'column', children: [
      _n('InkWell', glintId: 'ink_well_in_decorated_box', children: [
        _n('Text', glintId: 'text#aaaa', text: 'Create account'),
      ]),
      _n('Text', glintId: 'text#bbbb', text: 'Seven days to meet someone real'),
    ]);

    test('points a button label at the tappable ancestor', () {
      expect(idForLabel(root, 'Create account'), 'ink_well_in_decorated_box');
      expect(labelHint(root, 'create account '),
          contains('glintId:"ink_well_in_decorated_box"'));
    });

    test('plain text maps to the text node itself', () {
      expect(idForLabel(root, 'Seven days to meet someone real'), 'text#bbbb');
    });

    test('a label on an offstage page underneath is not suggested', () {
      final page = _n('InkWell', glintId: 'ink_well_in_welcome_page', children: [
        _n('Text', text: 'Create account'),
      ]);
      for (final n in page.walk()) {
        n.isOffstage = true;
      }
      expect(idForLabel(_n('Column', children: [page]), 'Create account'), isNull);
    });

    test('a label on the page underneath the current one is not suggested', () {
      final root = _n('Overlay', children: [
        _n('Scaffold', children: [
          _n('InkWell', glintId: 'ink_well_in_welcome_page', children: [
            _n('Text', text: 'Create account'),
          ]),
        ]),
        _n('Scaffold', children: [
          _n('InkWell', glintId: 'ink_well_in_stack', children: [
            _n('Text', text: 'Continue'),
          ]),
        ]),
      ]);
      expect(idForLabel(root, 'Create account'), isNull);
      expect(idForLabel(root, 'Continue'), 'ink_well_in_stack');
    });

    test('an id that matches no text gives no hint', () {
      expect(labelHint(root, 'checkbox'), isNull);
    });
  });

  group('swipeRegion', () {
    const screen = (x: 0.0, y: 0.0, w: 411.0, h: 600.0);

    test('narrows the screen to the scrollable', () {
      expect(swipeRegion(screen, (x: 0.0, y: 102.0, w: 411.0, h: 706.0)),
          (x: 0.0, y: 102.0, w: 411.0, h: 498.0));
    });

    test('falls back to the screen when the overlap is too small to swipe in', () {
      expect(swipeRegion(screen, (x: 0.0, y: 580.0, w: 411.0, h: 300.0)), screen);
    });

    test('no scrollable keeps the screen', () {
      expect(swipeRegion(screen, null), screen);
    });
  });
}
