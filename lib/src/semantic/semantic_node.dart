/// Module C — sealed SemanticNode hierarchy: a role-typed scene the
/// agent reads instead of the raw SceneNode tree.
library;

enum SemanticRole {
  page,
  appBar,
  button,
  input,
  text,
  icon,
  image,
  list,
  container,
  unknown,
}

enum Affordance { tappable, typeable, scrollable }

sealed class SemanticNode {
  SemanticNode({
    required this.glintId,
    required this.children,
    Set<Affordance>? affordances,
  }) : affordances = affordances ?? const <Affordance>{};

  /// Null when the node is purely structural.
  final String? glintId;
  final Set<Affordance> affordances;
  final List<SemanticNode> children;

  SemanticRole get role;

  /// Short label for the plain-text renderer; each variant picks the
  /// most useful field (button label, text content, etc.).
  String get displayLabel;

  /// Pre-order traversal.
  Iterable<SemanticNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }

  Map<String, Object?> toJson() => {
        'role': role.name,
        if (glintId != null) 'glintId': glintId,
        if (affordances.isNotEmpty)
          'affordances': affordances.map((a) => a.name).toList(),
        ..._extraJson(),
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
      };

  Map<String, Object?> _extraJson();
}

/// Top of the tree: a screen / route. Holds the optional [appBar] and a
/// flat [body]. The page itself isn't tappable.
class SemanticPage extends SemanticNode {
  SemanticPage({
    super.glintId,
    this.title,
    this.appBar,
    required List<SemanticNode> body,
  }) : super(
          children: [if (appBar != null) appBar, ...body],
        );

  final String? title;
  final SemanticAppBar? appBar;

  @override
  SemanticRole get role => SemanticRole.page;

  @override
  String get displayLabel => title ?? 'page';

  @override
  Map<String, Object?> _extraJson() => {
        if (title != null) 'title': title,
      };
}

class SemanticAppBar extends SemanticNode {
  SemanticAppBar({
    super.glintId,
    this.title,
    List<SemanticNode> actions = const [],
  }) : super(children: actions);

  final String? title;

  List<SemanticNode> get actions => children;

  @override
  SemanticRole get role => SemanticRole.appBar;

  @override
  String get displayLabel => title ?? 'app bar';

  @override
  Map<String, Object?> _extraJson() => {
        if (title != null) 'title': title,
      };
}

class SemanticButton extends SemanticNode {
  SemanticButton({
    super.glintId,
    this.label,
    super.children = const [],
  }) : super(affordances: const {Affordance.tappable});

  /// Best-effort human label — contained text or tooltip. Icons stay as
  /// children so [IconEnricher] can populate their name post-classify.
  final String? label;

  @override
  SemanticRole get role => SemanticRole.button;

  @override
  String get displayLabel => label ?? '';

  @override
  Map<String, Object?> _extraJson() => {
        if (label != null) 'label': label,
      };
}

class SemanticInput extends SemanticNode {
  SemanticInput({
    super.glintId,
    this.hint,
    this.currentValue,
  }) : super(
          children: const [],
          affordances: const {Affordance.typeable},
        );

  /// Placeholder / labelText. Populated by [InputEnricher] post-classify;
  /// stays null when the input doesn't expose one.
  String? hint;

  /// Live text in the field. Populated by [InputEnricher].
  String? currentValue;

  @override
  SemanticRole get role => SemanticRole.input;

  @override
  String get displayLabel {
    final parts = <String>[];
    if (hint != null && hint!.isNotEmpty) parts.add('($hint)');
    if (currentValue != null && currentValue!.isNotEmpty) {
      parts.add('"$currentValue"');
    }
    return parts.isEmpty ? 'input' : parts.join(' ');
  }

  @override
  Map<String, Object?> _extraJson() => {
        if (hint != null) 'hint': hint,
        if (currentValue != null) 'value': currentValue,
      };
}

class SemanticText extends SemanticNode {
  SemanticText({
    super.glintId,
    required this.content,
  }) : super(children: const []);

  final String content;

  @override
  SemanticRole get role => SemanticRole.text;

  @override
  String get displayLabel => '"$content"';

  @override
  Map<String, Object?> _extraJson() => {'content': content};
}

class SemanticIcon extends SemanticNode {
  SemanticIcon({
    super.glintId,
    this.name,
    this.codePoint,
  }) : super(children: const []);

  /// Set by [IconEnricher] when the codepoint matches a known table entry.
  String? name;

  /// Raw IconData codepoint, populated by [IconEnricher]. Hex-rendered
  /// in [displayLabel] as the fallback when [name] is unknown.
  int? codePoint;

  @override
  SemanticRole get role => SemanticRole.icon;

  @override
  String get displayLabel {
    if (name != null && name!.isNotEmpty) return name!;
    if (codePoint != null) {
      return 'U+${codePoint!.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    }
    return 'icon';
  }

  @override
  Map<String, Object?> _extraJson() => {
        if (name != null) 'name': name,
        if (codePoint != null) 'codePoint': codePoint,
      };
}

class SemanticImage extends SemanticNode {
  SemanticImage({
    super.glintId,
    this.source,
  }) : super(children: const []);

  final String? source;

  @override
  SemanticRole get role => SemanticRole.image;

  @override
  String get displayLabel => source ?? 'image';

  @override
  Map<String, Object?> _extraJson() => {
        if (source != null) 'source': source,
      };
}

class SemanticList extends SemanticNode {
  SemanticList({
    super.glintId,
    required super.children,
  }) : super(affordances: const {Affordance.scrollable});

  @override
  SemanticRole get role => SemanticRole.list;

  // direct-children count is misleading (a ListView often has 1 sliver
  // child wrapping N visible items). The renderer's indented body shows
  // the real shape.
  @override
  String get displayLabel => 'list';

  @override
  Map<String, Object?> _extraJson() => const {};
}

/// Anything that groups other nodes without a more specific role —
/// rows, columns, padding, etc. that survived the compaction pass.
class SemanticContainer extends SemanticNode {
  SemanticContainer({
    super.glintId,
    this.hint,
    required super.children,
  });

  /// Optional shape hint: 'row', 'column', 'stack', etc.
  final String? hint;

  @override
  SemanticRole get role => SemanticRole.container;

  @override
  String get displayLabel => hint ?? 'group';

  @override
  Map<String, Object?> _extraJson() => {
        if (hint != null) 'hint': hint,
      };
}

/// Floor classifier output — a node we know about but can't classify.
/// Keeps [label] for debugging and the original [glintId] so the agent
/// can still target it if it has to.
class SemanticUnknown extends SemanticNode {
  SemanticUnknown({
    super.glintId,
    required this.label,
    super.children = const [],
  });

  final String label;

  @override
  SemanticRole get role => SemanticRole.unknown;

  @override
  String get displayLabel => label;

  @override
  Map<String, Object?> _extraJson() => {'label': label};
}
