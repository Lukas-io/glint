import 'package:glint/glint.dart';
import 'package:test/test.dart';

import '../perception/fake_scene.dart';

SemanticContainer _row(int i,
    {bool withButton = true, String? toggle, String base = 'row_in_orders'}) =>
    SemanticContainer(
      glintId: '$base#${i.toRadixString(36).padLeft(3, '0')}',
      hint: 'row',
      children: [
        SemanticText(glintId: 'text_in_orders#$i', content: 'Order $i'),
        if (withButton)
          SemanticButton(
              glintId: 'button_in_orders#$i', label: 'Open', isToggle: toggle != null)
            ..toggleState = toggle,
      ],
    );

void main() {
  group('structuralSignature', () {
    test('rows with different text share a signature', () {
      expect(structuralSignature(_row(1)), structuralSignature(_row(2)));
    });

    test('a different toggle state or a missing button breaks it', () {
      expect(structuralSignature(_row(1, toggle: 'on')),
          isNot(structuralSignature(_row(2, toggle: 'off'))));
      expect(structuralSignature(_row(1)),
          isNot(structuralSignature(_row(2, withButton: false))));
    });
  });

  group('detectFoldRun', () {
    test('needs the threshold and stops at the first odd sibling', () {
      final kids = [_row(0), _row(1), _row(2), _row(3, withButton: false), _row(4)];
      expect(detectFoldRun(kids, 0, threshold: 4), isNull);
      expect(detectFoldRun(kids, 0, threshold: 3)?.length, 3);
      expect(detectFoldRun(kids, 3, threshold: 1)?.length, 1);
    });
  });

  group('PlainTextSceneRenderer folding', () {
    SemanticScene scene(List<SemanticNode> rows) => fakeSemanticScene(
          root: SemanticPage(body: [
            SemanticList(glintId: 'list_view_in_orders', children: rows),
          ]),
        );

    test('first row in full, then a digest with labels and #hash refs', () {
      final r = const PlainTextSceneRenderer()
          .renderDetailed(scene([for (var i = 0; i < 15; i++) _row(i)]));
      expect(r.text, contains('* button button_in_orders#0 Open'));
      expect(r.text, contains('… 14 more like it: "Order 1" #001, "Order 2" #002'));
      expect(r.text, contains('+4'));
      expect(r.text, isNot(contains('"Order 12"')));
      expect(r.runs.single.count, 15);
      expect(r.runs.single.listId, 'list_view_in_orders');
      expect(r.runs.single.lastItemId, 'row_in_orders#00e');
      expect(r.foldedItems, 14);
      expect(r.lineCount, lessThan(10));
    });

    test('an odd row in the middle stays visible in full', () {
      final rows = [for (var i = 0; i < 5; i++) _row(i), _row(5, withButton: false),
        for (var i = 6; i < 11; i++) _row(i)];
      final r = const PlainTextSceneRenderer().renderDetailed(scene(rows));
      expect(r.text, contains('"Order 5"'));
      expect(r.runs.length, 2);
    });

    test('fold off and subtree renders show every row', () {
      final s = scene([for (var i = 0; i < 8; i++) _row(i)]);
      final full = const PlainTextSceneRenderer().renderDetailed(s, fold: false);
      expect(full.text, contains('"Order 6"'));
      expect(full.runs, isEmpty);
      final sub = const PlainTextSceneRenderer()
          .renderSubtree(s.root.children.first);
      expect(sub, contains('"Order 7"'));
    });
  });

  group('JsonSceneRenderer folding', () {
    test('the tail of a run becomes one folded node', () {
      final s = fakeSemanticScene(
        root: SemanticPage(body: [
          SemanticList(
              glintId: 'list', children: [for (var i = 0; i < 6; i++) _row(i)]),
        ]),
      );
      final map = const JsonSceneRenderer().toMap(s);
      final list = ((map['root'] as Map)['children'] as List).first as Map;
      final kids = list['children'] as List;
      expect(kids.length, 2);
      final folded = (kids[1] as Map)['folded'] as Map;
      expect(folded['count'], 5);
      expect(folded['base'], 'row_in_orders');
      expect((folded['items'] as List).first, {'glintId': 'row_in_orders#001', 'label': 'Order 1'});
    });

    test('maxDepth replaces deeper children with a count', () {
      final s = fakeSemanticScene(
        root: SemanticPage(body: [SemanticList(glintId: 'list', children: [_row(0)])]),
      );
      final map = const JsonSceneRenderer().toMap(s, maxDepth: 1);
      final list = ((map['root'] as Map)['children'] as List).first as Map;
      expect(list['childCount'], 1);
      expect(list.containsKey('children'), isFalse);
    });
  });
}
