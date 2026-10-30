import '../../perception.dart';
import 'semantic_node.dart';

/// One widget-recognition rule. Lower priority runs first, first match wins;
/// [UnknownClassifier] is the floor.
abstract class WidgetClassifier {
  const WidgetClassifier();

  int get priority;
  bool matches(SceneNode node);
  SemanticNode build(SceneNode node, List<SemanticNode> children);
}

class ClassifierRegistry {
  ClassifierRegistry(List<WidgetClassifier> classifiers)
      : _classifiers = [...classifiers]..sort((a, b) => a.priority.compareTo(b.priority));

  factory ClassifierRegistry.defaults() => ClassifierRegistry(const [
        PageClassifier(),
        AppBarClassifier(),
        InputClassifier(),
        ToggleClassifier(),
        ButtonClassifier(),
        SegmentedClassifier(),
        TabBarClassifier(),
        ListClassifier(),
        TextClassifier(),
        IconClassifier(),
        ImageClassifier(),
        MapClassifier(),
        ContainerClassifier(),
        UnknownClassifier(),
      ]);

  final List<WidgetClassifier> _classifiers;

  WidgetClassifier classifierFor(SceneNode node) {
    for (final c in _classifiers) {
      if (c.matches(node)) return c;
    }
    throw StateError('no classifier matched ${node.label} — UnknownClassifier should be the floor');
  }
}

// ---------------------------------------------------------------------------
// Helpers shared by the classifiers below.
// ---------------------------------------------------------------------------

bool _labelOneOf(SceneNode n, Set<String> names) => names.contains(n.baseLabel);

String? _firstTextIn(List<SemanticNode> nodes) {
  for (final n in nodes) {
    if (n is SemanticText) return n.content;
    final inner = _firstTextIn(n.children);
    if (inner != null) return inner;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Concrete classifiers, top of priority list first.
// ---------------------------------------------------------------------------

/// Material's [Scaffold] is the canonical page root; the compactor later
/// hoists the [SemanticPage] up through ancestor containers to the tree root.
class PageClassifier extends WidgetClassifier {
  const PageClassifier();

  @override
  int get priority => 10;

  @override
  bool matches(SceneNode node) => kPageScaffolds.contains(node.label);

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // Offstage Scaffolds never reach here — Semanticizer short-circuits them.
    SemanticAppBar? appBar;
    final body = <SemanticNode>[];
    for (final c in children) {
      if (appBar == null && c is SemanticAppBar) {
        appBar = c;
      } else {
        body.add(c);
      }
    }
    return SemanticPage(
      glintId: node.glintId,
      appBar: appBar,
      body: body,
    );
  }
}

class AppBarClassifier extends WidgetClassifier {
  const AppBarClassifier();

  @override
  int get priority => 20;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, const {'AppBar', 'SliverAppBar', 'CupertinoNavigationBar'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // Keep the buttons — the leading back button and the action buttons
    // (search, menu, …) live in the AppBar's subtree. Dropping them (the old
    // `actions: const []`) made back-navigation and app-bar actions invisible.
    final buttons = <SemanticNode>[];
    void collect(List<SemanticNode> ns) {
      for (final n in ns) {
        if (n is SemanticButton || (n is SemanticContainer && n.hint == 'tabs')) {
          buttons.add(n);
        } else {
          collect(n.children);
        }
      }
    }

    collect(children);
    return SemanticAppBar(
      glintId: node.glintId,
      title: _titleIn(children),
      actions: buttons,
    );
  }

  /// First text NOT inside a button — the title, not a button's caption.
  String? _titleIn(List<SemanticNode> nodes) {
    for (final n in nodes) {
      if (n is SemanticButton) continue;
      if (n is SemanticText) return n.content;
      final inner = _titleIn(n.children);
      if (inner != null) return inner;
    }
    return null;
  }
}

class InputClassifier extends WidgetClassifier {
  const InputClassifier();

  @override
  int get priority => 30;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, const {
        'TextField',
        'TextFormField',
        'EditableText',
        'CupertinoTextField',
      });

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // hint + currentValue are filled later by InputEnricher via property reads.
    return SemanticInput(glintId: node.glintId);
  }
}

/// Checkbox / Switch / Radio and their ListTile forms — tappable one-liners;
/// a ListTile's inner toggle widget is absorbed, the tile is the tap target.
class ToggleClassifier extends WidgetClassifier {
  const ToggleClassifier();

  @override
  int get priority => 35;

  static const _toggleLabels = {
    'Checkbox',
    'Switch',
    'Radio',
    'CupertinoSwitch',
    'CupertinoCheckbox',
    'CheckboxListTile',
    'SwitchListTile',
    'RadioListTile',
  };

  @override
  bool matches(SceneNode node) => _labelOneOf(node, _toggleLabels);

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticButton(
      glintId: node.glintId,
      label: _firstTextIn(children),
      isToggle: true,
    );
  }
}

/// A segmented control: Flutter builds each segment's button itself, so only the app's segment labels reach the scene; each label becomes the button to tap.
class SegmentedClassifier extends WidgetClassifier {
  const SegmentedClassifier();

  @override
  int get priority => 45;

  @override
  bool matches(SceneNode node) =>
      _labelOneOf(node, const {'SegmentedButton', 'CupertinoSegmentedControl', 'CupertinoSlidingSegmentedControl'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    List<SemanticNode> segments(List<SemanticNode> ns) => [
          for (final n in ns)
            if (n is SemanticText)
              SemanticButton(glintId: n.glintId, label: n.content)
            else if (n is SemanticButton)
              n
            else
              ...segments(n.children),
        ];
    return SemanticContainer(glintId: node.glintId, hint: 'segments', children: segments(children));
  }
}

/// A navigation bar: its destinations' labels are strings, so only their icons reach the scene; each item becomes a tab button that `TabLabelEnricher` names.
class TabBarClassifier extends WidgetClassifier {
  const TabBarClassifier();

  static const labels = {'NavigationBar', 'BottomNavigationBar', 'NavigationRail', 'CupertinoTabBar', 'TabBar'};

  @override
  int get priority => 46;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, labels);

  /// One tab per item the app built (a destination, an item's icon, a Tab), even when the item reads as empty, since its label is a string the enricher fills.
  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) => SemanticContainer(
        glintId: node.glintId,
        hint: 'tabs',
        children: [
          for (final raw in node.children.where((c) => !c.isOffstage))
            SemanticButton(glintId: raw.glintId, children: [
              for (final c in children)
                if (c is SemanticIcon && c.glintId == raw.glintId) c,
            ]),
        ],
      );
}

class ButtonClassifier extends WidgetClassifier {
  const ButtonClassifier();

  @override
  int get priority => 40;

  static const _buttonLabels = {
    'FloatingActionButton',
    'ElevatedButton',
    'TextButton',
    'OutlinedButton',
    'FilledButton',
    'IconButton',
    'MaterialButton',
    'CupertinoButton',
    'BackButton',
    'CloseButton',
    'DrawerButton',
    'EndDrawerButton',
    'CupertinoNavigationBarBackButton',
    'PopupMenuButton',
    'DropdownButton',
    'ChoiceChip',
    'FilterChip',
    'InputChip',
    'ActionChip',
    'RawChip',
    'InkWell',
    'GestureDetector',
  };

  /// What the framework's own app bar buttons say (their tooltips), since they carry no text.
  static const _implicitLabels = {
    'BackButton': 'Back',
    'CupertinoNavigationBarBackButton': 'Back',
    'CloseButton': 'Close',
    'DrawerButton': 'Open navigation menu',
    'EndDrawerButton': 'Open menu',
  };

  @override
  bool matches(SceneNode node) => _labelOneOf(node, _buttonLabels);

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // A tap-wrapper around rich content (keyboard-dismiss GestureDetector,
    // tappable card) must keep its subtree — absorbing it blinds the agent.
    if (_wrapsRichContent(children)) {
      return SemanticButton(glintId: node.glintId, children: children);
    }
    // Leaf button: absorb caption text into the label; keep Icon / Image as
    // children so the IconEnricher can populate them post-classify.
    final label = _captionIn(children) ?? _implicitLabels[node.baseLabel];
    final kept = children.where((c) => c is SemanticIcon || c is SemanticImage).toList();
    return SemanticButton(
      glintId: node.glintId,
      label: label,
      children: kept,
    );
  }

  /// True when the subtree holds interactive/structural nodes or 3+ texts —
  /// content, not a caption.
  bool _wrapsRichContent(List<SemanticNode> children) {
    var texts = 0;
    for (final c in children) {
      for (final n in c.walk()) {
        if (n is SemanticInput ||
            n is SemanticButton ||
            n is SemanticList ||
            n is SemanticPage ||
            n is SemanticAppBar) {
          return true;
        }
        if (n is SemanticText && ++texts > 2) return true;
      }
    }
    return false;
  }

  /// Caption label: up to two texts joined with ' · ' so a subtitle survives.
  String? _captionIn(List<SemanticNode> nodes) {
    final texts = <String>[];
    void visit(List<SemanticNode> ns) {
      for (final n in ns) {
        if (texts.length >= 2) return;
        if (n is SemanticText) texts.add(n.content);
        visit(n.children);
      }
    }

    visit(nodes);
    return texts.isEmpty ? null : texts.join(' · ');
  }
}

class ListClassifier extends WidgetClassifier {
  const ListClassifier();

  @override
  int get priority => 50;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, const {
        'ListView',
        'GridView',
        'CustomScrollView',
        'Scrollable',
        'PageView',
        'NestedScrollView',
        'SingleChildScrollView',
        'ListWheelScrollView',
        'CupertinoPicker',
        'ReorderableListView',
      });

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticList(glintId: node.glintId, children: children);
  }
}

class TextClassifier extends WidgetClassifier {
  const TextClassifier();

  @override
  int get priority => 60;

  @override
  bool matches(SceneNode node) => node.textPreview != null && node.textPreview!.isNotEmpty;

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticText(glintId: node.glintId, content: node.textPreview!);
  }
}

class IconClassifier extends WidgetClassifier {
  const IconClassifier();

  @override
  int get priority => 70;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, const {'Icon', 'ImageIcon'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // IconData name needs a property read — deferred to IconEnricher.
    return SemanticIcon(glintId: node.glintId);
  }
}

class ImageClassifier extends WidgetClassifier {
  const ImageClassifier();

  @override
  int get priority => 80;

  @override
  bool matches(SceneNode node) =>
      _labelOneOf(node, const {'Image', 'RawImage', 'FadeInImage'}) ||
      (node.children.isEmpty && _labelOneOf(node, const {'CircleAvatar', 'Ink'}));

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticImage(glintId: node.glintId);
  }
}

/// A Google map: a platform view whose widget subtree says nothing; `MapEnricher` reads what it shows.
class MapClassifier extends WidgetClassifier {
  const MapClassifier();

  @override
  int get priority => 85;

  @override
  bool matches(SceneNode node) => _labelOneOf(node, const {'GoogleMap'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) => SemanticMap(glintId: node.glintId);
}

class ContainerClassifier extends WidgetClassifier {
  const ContainerClassifier();

  @override
  int get priority => 90;

  static const _containerLabels = {
    'MaterialApp',
    'WidgetsApp',
    'CupertinoApp',
    'SnackBar',
    'MaterialBanner',
    'Theme',
    'DefaultTextStyle',
    'MediaQuery',
    'SafeArea',
    'Material',
    'Card',
    'ListTile',
    'ExpansionTile',
    'Container',
    'DecoratedBox',
    'ColoredBox',
    'Padding',
    'Center',
    'Align',
    'SizedBox',
    'ConstrainedBox',
    'FractionallySizedBox',
    'AspectRatio',
    'Expanded',
    'Flexible',
    'Spacer',
    'Column',
    'Row',
    'Stack',
    'Positioned',
    'Wrap',
    'Flow',
    'IndexedStack',
    'Opacity',
    'Visibility',
    'AbsorbPointer',
    'IgnorePointer',
    'Hero',
    'AnimatedBuilder',
    'Builder',
    'LayoutBuilder',
    'StatefulBuilder',
    'Form',
    'Divider',
    'VerticalDivider',
    'ClipRRect',
    'ClipRect',
    'ClipOval',
    'ClipPath',
  };

  @override
  bool matches(SceneNode node) => _labelOneOf(node, _containerLabels);

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticContainer(
      glintId: node.glintId,
      hint: _hintFor(node.label),
      children: children,
    );
  }

  String? _hintFor(String label) => switch (label) {
        'Row' || 'Wrap' => 'row',
        'Column' => 'column',
        'Stack' || 'IndexedStack' => 'stack',
        'Form' => 'form',
        'Card' => 'card',
        'ListTile' || 'ExpansionTile' => 'tile',
        // Transient messages — the agent should read them but not treat them
        // as permanent UI or a blocking modal.
        'SnackBar' => 'snackbar (transient)',
        'MaterialBanner' => 'banner (transient)',
        _ => null,
      };
}

/// Floor — matches everything; keeps the original widget label.
class UnknownClassifier extends WidgetClassifier {
  const UnknownClassifier();

  @override
  int get priority => 1000;

  @override
  bool matches(SceneNode node) => true;

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticUnknown(
      glintId: node.glintId,
      label: node.label,
      children: children,
    );
  }
}
