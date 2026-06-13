import 'package:glint/glint.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// SceneNode builders — same shape as the perception tests'.
// ---------------------------------------------------------------------------

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
    inspectorId: 'inspector-$label',
    widgetRuntimeType: label,
    locationId: locationId,
    textPreview: textPreview,
    children: children,
  );
}

SceneNode _rooted(SceneNode root) {
  void recurse(SceneNode n, int depth) {
    for (var i = 0; i < n.children.length; i++) {
      final c = n.children[i];
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

/// Build a small counter-app-shaped scene: App > MaterialApp > Page >
/// Scaffold(AppBar+Body) and assign stable ids.
SceneNode _counterScene() {
  final tree = _rooted(_n('CounterApp', children: [
    _n('MaterialApp', children: [
      _n('CounterPage', children: [
        _n('Scaffold', children: [
          _n('AppBar', children: [
            _n('Text', textPreview: 'glint counter fixture'),
          ]),
          _n('SingleChildScrollView', children: [
            _n('Column', children: [
              _n('Padding', children: [
                _n('Text',
                    textPreview: 'You have pushed the button this many times:'),
              ]),
              _n('Text', textPreview: '0'),
              _n('TextField'),
              _n('SizedBox', children: [_n('Text', textPreview: 'scroll row 0')]),
            ]),
          ]),
          _n('FloatingActionButton', children: [
            _n('Icon'),
          ]),
        ]),
      ]),
    ]),
  ]));
  StableIdGenerator().assignIds(tree);
  return tree;
}

void main() {
  group('SemanticNode', () {
    test('toJson surfaces role, glintId, affordances, children', () {
      final btn = SemanticButton(
        glintId: 'fab',
        label: 'increment',
        children: const [],
      );
      expect(btn.toJson(), {
        'role': 'button',
        'glintId': 'fab',
        'affordances': ['tappable'],
        'label': 'increment',
      });
    });
  });

  group('ClassifierRegistry.defaults', () {
    final reg = ClassifierRegistry.defaults();

    SemanticNode classify(SceneNode n) => reg.classifierFor(n).build(n, const []);

    test('Scaffold becomes a SemanticPage', () {
      expect(classify(_n('Scaffold')), isA<SemanticPage>());
    });
    test('AppBar becomes a SemanticAppBar', () {
      expect(classify(_n('AppBar')), isA<SemanticAppBar>());
    });
    test('FloatingActionButton becomes a SemanticButton with tappable', () {
      final n = classify(_n('FloatingActionButton'));
      expect(n, isA<SemanticButton>());
      expect(n.affordances, contains(Affordance.tappable));
    });
    test('TextField becomes a SemanticInput with typeable', () {
      final n = classify(_n('TextField'));
      expect(n, isA<SemanticInput>());
      expect(n.affordances, contains(Affordance.typeable));
    });
    test('SingleChildScrollView becomes a SemanticList with scrollable', () {
      final n = classify(_n('SingleChildScrollView'));
      expect(n, isA<SemanticList>());
      expect(n.affordances, contains(Affordance.scrollable));
    });
    test('Text with textPreview becomes a SemanticText carrying content', () {
      final n = classify(_n('Text', textPreview: 'hello'));
      expect(n, isA<SemanticText>());
      expect((n as SemanticText).content, 'hello');
    });
    test('Column → SemanticContainer with hint "column"', () {
      final n = classify(_n('Column'));
      expect(n, isA<SemanticContainer>());
      expect((n as SemanticContainer).hint, 'column');
    });
    test('Unknown widget falls through to SemanticUnknown', () {
      final n = classify(_n('SomeCustomWidget'));
      expect(n, isA<SemanticUnknown>());
      expect((n as SemanticUnknown).label, 'SomeCustomWidget');
    });
  });

  group('Semanticizer end-to-end on counter scene', () {
    final tree = _counterScene();
    final root = Semanticizer()._classifyForTest(tree);

    test('classifies the root chain as a single SemanticPage at the top', () {
      // Compactor.hoistPage runs in semanticize(); confirm the page is
      // reachable.
      expect(root.walk().whereType<SemanticPage>().length, 1);
    });

    test('page contains the app bar with its title text', () {
      final page = root.walk().whereType<SemanticPage>().first;
      expect(page.appBar?.title, 'glint counter fixture');
    });

    test('FAB carries the icon and tappable affordance', () {
      final btn = root.walk().whereType<SemanticButton>().first;
      expect(btn.affordances, contains(Affordance.tappable));
      expect(btn.glintId, 'floating_action_button');
    });

    test('the scrollable surface keeps its scrollable affordance', () {
      final list = root.walk().whereType<SemanticList>().firstOrNull;
      expect(list, isNotNull);
      expect(list!.affordances, contains(Affordance.scrollable));
    });

    test('text content survives into SemanticText nodes', () {
      final texts =
          root.walk().whereType<SemanticText>().map((t) => t.content).toList();
      expect(texts, contains('0'));
      expect(texts,
          contains('You have pushed the button this many times:'));
    });

    test('input appears with typeable affordance', () {
      final input = root.walk().whereType<SemanticInput>().firstOrNull;
      expect(input, isNotNull);
      expect(input!.affordances, contains(Affordance.typeable));
    });
  });

  group('SceneCompactor', () {
    const c = SceneCompactor();

    test('expandChild splices nameless containers without hint', () {
      final inner = SemanticText(content: 'x');
      final wrapper =
          SemanticContainer(children: [inner]); // no glintId, no hint
      expect(c.expandChild(wrapper), [inner]);
    });
    test('expandChild keeps containers with a hint', () {
      final inner = SemanticText(content: 'x');
      final col = SemanticContainer(hint: 'column', children: [inner]);
      expect(c.expandChild(col), [col]);
    });
    test('expandChild folds named containers without a hint', () {
      // A glintId alone isn't reason to keep a structural wrapper —
      // hint is the signal to preserve.
      final inner = SemanticText(content: 'x');
      final named = SemanticContainer(glintId: 'my_box', children: [inner]);
      expect(c.expandChild(named), [inner]);
    });

    test('expandChild folds child-bearing unknowns regardless of glintId', () {
      final inner = SemanticText(content: 'x');
      final wrap =
          SemanticUnknown(glintId: 'custom', label: 'MyWidget', children: [inner]);
      expect(c.expandChild(wrap), [inner]);
    });

    test('expandChild keeps leaf unknowns so they stay visible', () {
      final leaf = SemanticUnknown(glintId: 'x', label: 'MyWidget');
      expect(c.expandChild(leaf), [leaf]);
    });
    test('hoistPage surfaces a page nested under wrappers', () {
      final page = SemanticPage(body: const []);
      final outer = SemanticUnknown(
          label: 'CustomApp',
          children: [SemanticContainer(hint: 'col', children: [page])]);
      expect(c.hoistPage(outer), page);
    });
  });

  group('PlainTextSceneRenderer', () {
    test('emits affordance markers + role + glintId + label', () {
      final scene = SemanticScene(
        sourceScene: _FakeScene(),
        root: SemanticPage(
          glintId: 'p',
          title: 'home',
          appBar: SemanticAppBar(title: 'home'),
          body: [
            SemanticText(content: 'hi'),
            SemanticButton(glintId: 'fab', label: 'add'),
            SemanticInput(glintId: 'name', hint: 'name'),
            SemanticList(children: [SemanticText(content: 'row 0')]),
          ],
        ),
      );
      final out = const PlainTextSceneRenderer().render(scene);
      // Compact form: no brackets around glintId, marker + role + id + label.
      expect(out, contains('- page p home'));
      expect(out, contains('- appBar'));
      expect(out, contains('* button fab add'));
      expect(out, contains('> input name'));
      expect(out, contains('<> list'));
      expect(out, contains('"hi"'));
    });

    test('collapses runs of identical-role siblings sharing an id prefix', () {
      final rows = [
        for (var i = 0; i < 30; i++)
          SemanticText(
            glintId: 'row#${i.toRadixString(36)}',
            content: 'item $i',
          ),
      ];
      final scene = SemanticScene(
        sourceScene: _FakeScene(),
        root: SemanticPage(body: rows),
      );
      final out = const PlainTextSceneRenderer().render(scene);
      // First row shown in full, last row name surfaced in the summary
      // line, intermediate rows folded away.
      expect(out, contains('"item 0"'));
      expect(out, contains('"item 29"'));
      expect(out, contains('row#* (29 more'));
      // A middle item should NOT appear at all — folded by the run.
      expect(out, isNot(contains('"item 5"')));
      expect(out, isNot(contains('"item 15"')));
    });
  });
}

// Test-only access to Semanticizer's classify pipeline so we can run it
// against a hand-built tree without a real Scene.
extension on Semanticizer {
  SemanticNode _classifyForTest(SceneNode root) {
    final classified = _classifyRec(root);
    return const SceneCompactor().hoistPage(classified);
  }

  SemanticNode _classifyRec(SceneNode node) {
    final children = node.children
        .map(_classifyRec)
        .expand(const SceneCompactor().expandChild)
        .toList();
    return ClassifierRegistry.defaults().classifierFor(node).build(node, children);
  }
}

/// Bare scene stub for the renderer test. We never touch it.
class _FakeScene implements Scene {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
