import '../../perception.dart';
import 'semantic_node.dart';

/// One widget-recognition rule. Lower priority runs first; first match
/// wins. [UnknownClassifier] is the floor.
abstract class WidgetClassifier {
  const WidgetClassifier();

  int get priority;
  bool matches(SceneNode node);
  SemanticNode build(SceneNode node, List<SemanticNode> children);
}

class ClassifierRegistry {
  ClassifierRegistry(List<WidgetClassifier> classifiers)
      : _classifiers = [...classifiers]
          ..sort((a, b) => a.priority.compareTo(b.priority));

  factory ClassifierRegistry.defaults() => ClassifierRegistry(const [
        PageClassifier(),
        AppBarClassifier(),
        InputClassifier(),
        ButtonClassifier(),
        ListClassifier(),
        TextClassifier(),
        IconClassifier(),
        ImageClassifier(),
        ContainerClassifier(),
        UnknownClassifier(),
      ]);

  final List<WidgetClassifier> _classifiers;

  WidgetClassifier classifierFor(SceneNode node) {
    for (final c in _classifiers) {
      if (c.matches(node)) return c;
    }
    throw StateError(
        'no classifier matched ${node.label} — UnknownClassifier should be the floor');
  }
}

// ---------------------------------------------------------------------------
// Helpers shared by the classifiers below.
// ---------------------------------------------------------------------------

bool _labelOneOf(SceneNode n, Set<String> names) => names.contains(n.label);

String? _firstTextIn(List<SemanticNode> nodes) {
  for (final n in nodes) {
    if (n is SemanticText) return n.content;
    final inner = _firstTextIn(n.children);
    if (inner != null) return inner;
  }
  return null;
}

SemanticIcon? _firstIconIn(List<SemanticNode> nodes) {
  for (final n in nodes) {
    if (n is SemanticIcon) return n;
    final inner = _firstIconIn(n.children);
    if (inner != null) return inner;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Concrete classifiers, top of priority list first.
// ---------------------------------------------------------------------------

/// Material's [Scaffold] is the canonical page root. The semanticizer's
/// compactor lifts a [SemanticPage] up through ancestor containers so it
/// ends up at the tree root.
class PageClassifier extends WidgetClassifier {
  const PageClassifier();

  @override
  int get priority => 10;

  @override
  bool matches(SceneNode node) => node.label == 'Scaffold';

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
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
  bool matches(SceneNode node) =>
      _labelOneOf(node, const {'AppBar', 'SliverAppBar', 'CupertinoNavigationBar'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticAppBar(
      glintId: node.glintId,
      title: _firstTextIn(children),
      actions: const [],
    );
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
    // hint + currentValue need a property read against InputDecoration
    // / TextEditingController — Module C v2.
    return SemanticInput(glintId: node.glintId);
  }
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
    'PopupMenuButton',
    'DropdownButton',
    'InkWell',
    'GestureDetector',
  };

  @override
  bool matches(SceneNode node) => _buttonLabels.contains(node.label);

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    final label = _firstTextIn(children);
    final icon = _firstIconIn(children);
    return SemanticButton(
      glintId: node.glintId,
      label: label,
      iconName: icon?.name,
    );
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
  bool matches(SceneNode node) =>
      node.textPreview != null && node.textPreview!.isNotEmpty;

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
  bool matches(SceneNode node) =>
      _labelOneOf(node, const {'Icon', 'ImageIcon'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    // IconData name needs a property read — deferred.
    return SemanticIcon(glintId: node.glintId);
  }
}

class ImageClassifier extends WidgetClassifier {
  const ImageClassifier();

  @override
  int get priority => 80;

  @override
  bool matches(SceneNode node) =>
      _labelOneOf(node, const {'Image', 'RawImage', 'FadeInImage'});

  @override
  SemanticNode build(SceneNode node, List<SemanticNode> children) {
    return SemanticImage(glintId: node.glintId);
  }
}

class ContainerClassifier extends WidgetClassifier {
  const ContainerClassifier();

  @override
  int get priority => 90;

  static const _containerLabels = {
    'MaterialApp',
    'WidgetsApp',
    'CupertinoApp',
    'Theme',
    'DefaultTextStyle',
    'MediaQuery',
    'SafeArea',
    'Material',
    'Card',
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
  bool matches(SceneNode node) => _containerLabels.contains(node.label);

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
