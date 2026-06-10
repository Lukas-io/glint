import 'package:glint/glint.dart';
import 'package:test/test.dart';

// Helpers for building a minimal SceneNode tree by hand so we can exercise
// the id generator without running a real VM.
SceneNode _n(
  String label, {
  List<SceneNode> children = const [],
  int? locationId,
  String? textPreview,
}) {
  return SceneNode(
    depth: 0,
    indexInParent: -1,
    description: label,
    type: '_ElementDiagnosticableTreeNode',
    inspectorId: 'inspector-x',
    widgetRuntimeType: label,
    locationId: locationId,
    textPreview: textPreview,
    children: children,
  );
}

/// Re-assigns depth + indexInParent so a hand-built tree has the same
/// invariants the inspector parser maintains.
SceneNode _rooted(SceneNode root) {
  void recurse(SceneNode n, int depth) {
    for (var i = 0; i < n.children.length; i++) {
      final c = n.children[i];
      // SceneNode fields are final, so swap in a fresh one with the right
      // depth/index, preserving children + value fields.
      final fixed = SceneNode(
        depth: depth + 1,
        indexInParent: i,
        description: c.description,
        type: c.type,
        inspectorId: c.inspectorId,
        widgetRuntimeType: c.widgetRuntimeType,
        locationId: c.locationId,
        textPreview: c.textPreview,
        createdByLocalProject: c.createdByLocalProject,
        stateful: c.stateful,
        hasChildren: c.hasChildren,
        children: c.children,
      );
      n.children[i] = fixed;
      recurse(fixed, depth + 1);
    }
  }

  recurse(root, root.depth);
  return root;
}

void main() {
  group('snake_case', () {
    test('PascalCase splits at upper-case boundaries', () {
      final tree = _rooted(_n('Root', children: [
        _n('FloatingActionButton'),
        _n('MaterialApp'),
        _n('Text'),
      ]));
      StableIdGenerator().assignIds(tree);
      final ids = tree.walk().map((n) => n.glintId).toList();
      expect(ids, [
        'root',
        'floating_action_button',
        'material_app',
        'text',
      ]);
    });

    test('underscored framework types are normalised', () {
      final tree = _rooted(_n('Root', children: [
        _n('_ElementDiagnosticableTreeNode'),
      ]));
      StableIdGenerator().assignIds(tree);
      expect(
        tree.children.first.glintId,
        'element_diagnosticable_tree_node',
      );
    });
  });

  group('unique base name', () {
    test('single instance gets the bare snake name', () {
      final tree = _rooted(_n('Root', children: [_n('FloatingActionButton')]));
      StableIdGenerator().assignIds(tree);
      expect(tree.children.first.glintId, 'floating_action_button');
    });
  });

  group('descriptive disambiguation', () {
    test('two siblings under a uniquely-named ancestor get scope suffix', () {
      final tree = _rooted(_n('Root', children: [
        _n('AppBar', children: [_n('Text', locationId: 1)]),
        _n('Body', children: [_n('Text', locationId: 2)]),
      ]));
      StableIdGenerator().assignIds(tree);
      final ids = {for (final n in tree.walk()) n.label: n.glintId};
      // Two Texts → both need disambiguation. AppBar's Text gets
      // `text_in_app_bar`, Body's Text gets `text_in_body`. No hash needed.
      expect(ids['Text'], anyOf('text_in_app_bar', 'text_in_body'));
      final allTextIds =
          tree.walk().where((n) => n.label == 'Text').map((n) => n.glintId).toSet();
      expect(allTextIds, {'text_in_app_bar', 'text_in_body'});
    });
  });

  group('hash fallback', () {
    test('two Texts under the same uniquely-named ancestor get hash suffixes',
        () {
      final tree = _rooted(_n('Root', children: [
        _n('Column', children: [
          _n('Text', locationId: 10),
          _n('Text', locationId: 11),
        ]),
      ]));
      StableIdGenerator().assignIds(tree);
      final textIds = tree
          .walk()
          .where((n) => n.label == 'Text')
          .map((n) => n.glintId!)
          .toList();
      expect(textIds, hasLength(2));
      expect(textIds.toSet(), hasLength(2)); // unique
      for (final id in textIds) {
        expect(id, matches(RegExp(r'^text_in_column#[a-z2-7]{4}$')));
      }
    });
  });

  group('stability', () {
    test('same tree shape produces same ids across runs', () {
      SceneNode build() => _rooted(_n('Root', children: [
            _n('Column', children: [
              _n('Text', locationId: 100),
              _n('Text', locationId: 101),
            ]),
          ]));
      final a = build();
      final b = build();
      StableIdGenerator().assignIds(a);
      StableIdGenerator().assignIds(b);
      final aIds = a.walk().map((n) => n.glintId).toList();
      final bIds = b.walk().map((n) => n.glintId).toList();
      expect(aIds, bIds);
    });

    test('changing textPreview does not change ids', () {
      // Counter-fixture pattern: same widget tree, different text content
      // — the id must NOT shift.
      final a = _rooted(_n('Root', children: [
        _n('Text', locationId: 5, textPreview: '0'),
      ]));
      final b = _rooted(_n('Root', children: [
        _n('Text', locationId: 5, textPreview: '42'),
      ]));
      StableIdGenerator()
        ..assignIds(a)
        ..assignIds(b);
      expect(a.children.first.glintId, b.children.first.glintId);
    });
  });

  group('global uniqueness', () {
    test('every node ends up with a unique id', () {
      final tree = _rooted(_n('Root', children: [
        _n('Column', children: [
          _n('Text', locationId: 1),
          _n('Text', locationId: 2),
          _n('Text', locationId: 3),
        ]),
        _n('Row', children: [
          _n('Text', locationId: 4),
          _n('Text', locationId: 5),
        ]),
      ]));
      StableIdGenerator().assignIds(tree);
      final ids = tree.walk().map((n) => n.glintId).toList();
      expect(ids.toSet().length, ids.length, reason: 'ids must be unique: $ids');
    });
  });
}
