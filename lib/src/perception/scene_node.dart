/// One node in the perception model.
///
/// Built from a single DiagnosticsNode entry in the inspector JSON returned
/// by `ext.flutter.inspector.getRootWidgetTree`. The fields here are what
/// Module B uses internally; the agent-facing semantic view (Module C, P3)
/// is derived from these.
///
/// `inspectorId` is the inspector's per-read object handle ("inspector-N").
/// It is reused for the duration of the inspector group but is NOT stable
/// across reads — for the agent's stable handle, see [SceneNode.glintId].
///
/// `locationId` is the inspector's source-location identifier (a per-file
/// integer) — stable across reads for the same widget instance at the same
/// source location. It is the bedrock of stable-id generation, but two
/// sibling instances of the same widget share a locationId, so it is not
/// unique on its own.
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

  /// 0 for the root; child depth = parent depth + 1.
  final int depth;

  /// Index of this node inside its parent's `children` array. -1 for the
  /// root. Used by the stable-id generator as a tiebreaker among siblings
  /// that share the same locationId.
  final int indexInParent;

  /// Diagnostic description, usually the widget runtime type
  /// (`"FloatingActionButton"`, `"Text"`). For non-widget framework nodes
  /// this can be something like `"_ElementDiagnosticableTreeNode"`.
  final String description;

  /// Diagnostics node type, e.g. `"_ElementDiagnosticableTreeNode"`.
  final String type;

  /// Inspector handle, valid only for the current inspector group.
  final String inspectorId;

  /// Stable source-location id (when the inspector emits one). Same widget
  /// at same source location → same locationId every read.
  final int? locationId;

  /// File / line / column / name from the inspector's creation tracking.
  final CreationLocation? creationLocation;

  /// Some framework-internal nodes carry their concrete widget runtime type
  /// in this field instead of in [description].
  final String? widgetRuntimeType;

  /// Text content for nodes that render text (RenderParagraph-backed).
  final String? textPreview;

  /// True for widgets whose creationLocation belongs to a directory the
  /// inspector considers "the user's code". Used by the agent-facing
  /// summary projection (P3) to keep framework chrome out by default.
  final bool createdByLocalProject;

  /// True for StatefulElement-style nodes.
  final bool stateful;

  /// Whether the inspector reported `hasChildren: true`. May be true even
  /// when `children` is empty in a summary tree.
  final bool hasChildren;

  /// Glint's stable, unique, agent-facing id (set after the stable-id pass
  /// runs on the assembled tree). Null until then.
  String? glintId;

  /// Children in tree order.
  List<SceneNode> children;

  /// The most useful single-word label for this node — `widgetRuntimeType`
  /// when present, otherwise `description`. Strips the framework-internal
  /// fallback (`_ElementDiagnosticableTreeNode`) by checking `description`
  /// only when it doesn't look like a synthetic type.
  String get label {
    if (widgetRuntimeType != null && widgetRuntimeType!.isNotEmpty) {
      return widgetRuntimeType!;
    }
    return description;
  }

  /// Walk this subtree in pre-order, yielding each node once.
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
