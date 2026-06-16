/// One node in the perception tree, parsed from inspector DiagnosticsNode JSON.
class SceneNode {
  SceneNode({
    required this.depth,
    required this.indexInParent,
    required this.description,
    required this.type,
    required this.inspectorId,
    this.locationId,
    this.creationLocation,
    this.widgetRuntimeType,
    this.textPreview,
    this.createdByLocalProject = false,
    this.stateful = false,
    this.hasChildren = false,
    this.glintId,
    this.children = const <SceneNode>[],
  });

  /// 0 for root; child = parent + 1.
  final int depth;

  /// -1 for root. Stable-id generator tiebreaker among siblings sharing a
  /// locationId.
  final int indexInParent;

  /// Usually the widget runtime type. Falls back to a framework-internal
  /// type name when the inspector emits one (e.g.
  /// `_ElementDiagnosticableTreeNode`).
  final String description;

  /// DiagnosticsNode `type` field — typically
  /// `"_ElementDiagnosticableTreeNode"`.
  final String type;

  /// Inspector handle (`"inspector-N"`). Valid only for the current
  /// inspector group; NOT stable across reads.
  final String inspectorId;

  /// Inspector source-location id — same widget at same source location
  /// produces the same value every read. Bedrock for stable-id generation
  /// but not unique on its own.
  final int? locationId;

  final CreationLocation? creationLocation;

  /// Some framework nodes carry the widget runtime type here instead of in
  /// [description].
  final String? widgetRuntimeType;

  /// RenderParagraph-backed nodes only.
  final String? textPreview;

  final bool createdByLocalProject;
  final bool stateful;
  final bool hasChildren;

  /// Glint's stable, unique, agent-facing id. Null until
  /// [StableIdGenerator.assignIds] runs over the tree.
  String? glintId;

  /// True when this node and its subtree are inside an [Offstage] widget with
  /// offstage=true — i.e. a non-active IndexedStack child or GoRouter shell
  /// branch. Offstage nodes have NaN/zero geometry and are excluded from
  /// addressable ids, scene rendering, and the [hoistPage] page selector.
  bool isOffstage = false;

  /// Screen-space bounding box for native (iOS AX) nodes.
  /// Null for Flutter widget-tree nodes (those use VM geometry eval instead).
  ({double x, double y, double w, double h})? axFrame;

  /// Whether the native element is enabled/interactive (from AX `enabled`).
  bool? isNativeEnabled;

  List<SceneNode> children;

  /// Best single-word label: widgetRuntimeType when present, else description.
  String get label =>
      (widgetRuntimeType != null && widgetRuntimeType!.isNotEmpty)
          ? widgetRuntimeType!
          : description;

  /// Pre-order traversal of this subtree.
  Iterable<SceneNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }

  Map<String, Object?> toJson() => {
        'glintId': glintId,
        'label': label,
        'inspectorId': inspectorId,
        if (locationId != null) 'locationId': locationId,
        if (textPreview != null) 'textPreview': textPreview,
        if (createdByLocalProject) 'createdByLocalProject': true,
        if (stateful) 'stateful': true,
        if (creationLocation != null)
          'creationLocation': creationLocation!.toJson(),
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
      };
}

class CreationLocation {
  CreationLocation({
    required this.file,
    required this.line,
    required this.column,
    this.name,
  });

  final String file;
  final int line;
  final int column;
  final String? name;

  Map<String, Object?> toJson() => {
        'file': file,
        'line': line,
        'column': column,
        if (name != null) 'name': name,
      };
}
