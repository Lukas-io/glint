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

  /// Usually the widget runtime type; falls back to a framework-internal type
  /// name (e.g. `_ElementDiagnosticableTreeNode`) when the inspector emits one.
  final String description;

  /// DiagnosticsNode `type` field — typically
  /// `"_ElementDiagnosticableTreeNode"`.
  final String type;

  /// Inspector handle (`"inspector-N"`). Valid only for the current
  /// inspector group; NOT stable across reads.
  final String inspectorId;

  /// Inspector source-location id — stable per source location across reads.
  /// Bedrock for stable-id generation but not unique on its own.
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

  /// True inside an offstage [Offstage] (non-active IndexedStack child or
  /// GoRouter shell branch). NaN/zero geometry, so excluded from addressable
  /// ids, scene rendering, and the [hoistPage] page selector.
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

  /// True when this node is a platform-view widget (GoogleMap, WebView, etc.)
  /// whose element context rejects ModalRoute and geometry evals (RPCError 113).
  bool get isPlatformView => _platformViewLabels.contains(label);

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

// ── platform view detection ────────────────────────────────────────────────

/// Widget labels whose element context rejects VM evals (RPCError 113).
const _platformViewLabels = {
  'GoogleMap',
  'AndroidView',
  'UiKitView',
  'PlatformViewLink',
  'WebView',
  'WebViewWidget',
  'HtmlElementView',
  'TextureLayer',
};

/// Max summary-tree depth at which a node is "shallow enough" for an accurate
/// outer ModalRoute name. Deeper nodes are usually inside a GoRouter ShellRoute
/// inner navigator or an off-screen PageView page.
const kShallowProbeMaxDepth = 12;

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
