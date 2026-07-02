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

  group('ButtonClassifier wrapper behavior', () {
    SemanticNode classifyTree(SceneNode root) {
      final tree = _rooted(root);
      StableIdGenerator().assignIds(tree);
      return Semanticizer()._classifyForTest(tree);
    }

    test('full-page GestureDetector wrapper keeps its subtree', () {
      final root = classifyTree(_n('Scaffold', children: [
        _n('GestureDetector', children: [
          _n('Column', children: [
            _n('Text', textPreview: 'Welcome back'),
            _n('TextField'),
            _n('ElevatedButton', children: [_n('Text', textPreview: 'Continue')]),
          ]),
        ]),
      ]));
      final wrapper = root.walk().whereType<SemanticButton>().first;
      expect(wrapper.children, isNotEmpty, reason: 'wrapper must not swallow content');
      expect(root.walk().whereType<SemanticInput>(), isNotEmpty);
      expect(root.walk().whereType<SemanticText>().map((t) => t.content),
          contains('Welcome back'));
      expect(root.walk().whereType<SemanticButton>().map((b) => b.label),
          contains('Continue'));
    });

    test('GestureDetector around plain caption stays a leaf button', () {
      final root = classifyTree(_n('Scaffold', children: [
        _n('GestureDetector', children: [_n('Text', textPreview: 'AeTrust')]),
      ]));
      final btn = root.walk().whereType<SemanticButton>().first;
      expect(btn.label, 'AeTrust');
      expect(btn.children, isEmpty);
    });

    test('leaf button joins two caption texts', () {
      final root = classifyTree(_n('Scaffold', children: [
        _n('ElevatedButton', children: [
          _n('Text', textPreview: 'Buy'),
          _n('Text', textPreview: r'$4.99'),
        ]),
      ]));
      final btn = root.walk().whereType<SemanticButton>().first;
      expect(btn.label, r'Buy · $4.99');
      expect(btn.children, isEmpty);
    });

    test('three or more texts marks the tappable as a wrapper', () {
      final root = classifyTree(_n('Scaffold', children: [
        _n('GestureDetector', children: [
          _n('Text', textPreview: 'title'),
          _n('Text', textPreview: 'subtitle'),
          _n('Text', textPreview: 'caption'),
        ]),
      ]));
      final btn = root.walk().whereType<SemanticButton>().first;
      expect(btn.children, hasLength(3));
      expect(btn.label, isNull);
    });
  });

  group('offstage subtrees', () {
    test('contribute nothing to the scene', () {
      final tree = _rooted(_n('Scaffold', children: [
        _n('IndexedStack', children: [
          _n('Column', children: [_n('Text', textPreview: 'active tab')]),
          _n('Column', children: [_n('Text', textPreview: 'hidden tab')]),
        ]),
      ]));
      StableIdGenerator().assignIds(tree);
      final stack =
          tree.walk().firstWhere((n) => n.label == 'IndexedStack');
      for (final n in stack.children[1].walk()) {
        n.isOffstage = true;
      }
      final root = Semanticizer()._classifyForTest(tree);
      final texts =
          root.walk().whereType<SemanticText>().map((t) => t.content);
      expect(texts, contains('active tab'));
      expect(texts, isNot(contains('hidden tab')));
    });
  });

  group('selectActivePage', () {
    final s = Semanticizer();

    test('stacked navigator routes: last onstage page wins', () {
      final home = SemanticPage(glintId: 'scaffold#home', body: const []);
      final details = SemanticPage(glintId: 'scaffold#details', body: const []);
      final tree = SemanticUnknown(
        label: 'Navigator',
        children: [home, details],
      );
      expect(s.selectActivePage(tree), same(details));
    });

    test('a page nested inside a page is never the route', () {
      final tab = SemanticPage(glintId: 'scaffold#tab', body: const []);
      final route = SemanticPage(glintId: 'scaffold#route', body: [
        SemanticList(glintId: 'page_view', children: [tab]),
      ]);
      expect(s.selectActivePage(route), same(route));
    });

    test('offstage scaffolds (classified unknown) are not candidates', () {
      final active = SemanticPage(glintId: 'scaffold#active', body: const []);
      final tree = SemanticUnknown(label: 'IndexedStack', children: [
        active,
        SemanticUnknown(glintId: null, label: 'offstage'),
      ]);
      expect(s.selectActivePage(tree), same(active));
    });

    test('no page falls back to the given root', () {
      final tree = SemanticUnknown(label: 'CustomApp', children: [
        SemanticText(glintId: 't', content: 'x'),
      ]);
      expect(s.selectActivePage(tree), same(tree));
    });
  });

  group('ToggleClassifier', () {
    final reg = ClassifierRegistry.defaults();

    test('Checkbox becomes a tappable SemanticButton', () {
      final n = reg.classifierFor(_n('Checkbox')).build(_n('Checkbox'), const []);
      expect(n, isA<SemanticButton>());
      expect(n.affordances, contains(Affordance.tappable));
    });

    test('CheckboxListTile absorbs its inner toggle and takes the title', () {
      final tile = _n('CheckboxListTile', children: [
        _n('Text', textPreview: 'Remember me'),
        _n('Checkbox'),
      ]);
      final tree = _rooted(_n('Scaffold', children: [tile]));
      StableIdGenerator().assignIds(tree);
      final root = Semanticizer()._classifyForTest(tree);
      final buttons = root.walk().whereType<SemanticButton>().toList();
      expect(buttons, hasLength(1), reason: 'inner Checkbox is absorbed');
      expect(buttons.single.label, 'Remember me');
    });

    test('generic runtime types match via baseLabel', () {
      final radio = _n('Radio<String>');
      final n = reg.classifierFor(radio).build(radio, const []);
      expect(n, isA<SemanticButton>());
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
    test('expandChild drops leaf framework plumbing (gaps, semantics)', () {
      for (final label in ['_RawGap', 'Semantics', 'SizedBox.expand']) {
        final leaf = SemanticUnknown(glintId: 'x', label: label);
        expect(c.expandChild(leaf), isEmpty, reason: label);
      }
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

    test('input renders hint when currentValue is unset', () {
      final input = SemanticInput(glintId: 'email_field')..hint = 'email';
      final scene = SemanticScene(
        sourceScene: _FakeScene(),
        root: SemanticPage(body: [input]),
      );
      final out = const PlainTextSceneRenderer().render(scene);
      expect(out, contains('> input email_field (email)'));
    });

    test('input renders both hint and currentValue when both set', () {
      final input = SemanticInput(glintId: 'email_field')
        ..hint = 'email'
        ..currentValue = 'a@b';
      final scene = SemanticScene(
        sourceScene: _FakeScene(),
        root: SemanticPage(body: [input]),
      );
      final out = const PlainTextSceneRenderer().render(scene);
      expect(out, contains('> input email_field (email) "a@b"'));
    });

    test('multiline label renders on one line', () {
      final scene = SemanticScene(
        sourceScene: _FakeScene(),
        root: SemanticPage(body: [
          SemanticText(glintId: 'title', content: 'the\nGreat Wall'),
        ]),
      );
      final out = const PlainTextSceneRenderer().render(scene);
      expect(out, contains('"the Great Wall"'));
      expect(out, isNot(contains('the\nGreat')));
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

// Test-only entry: run the real classify pipeline (via classifyNode) against
// a hand-built tree without a real Scene, then hoist like semanticize() does.
extension on Semanticizer {
  SemanticNode _classifyForTest(SceneNode root) {
    return const SceneCompactor().hoistPage(classifyNode(root));
  }
}

/// Bare scene stub for the renderer test. We never touch it.
class _FakeScene implements Scene {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
