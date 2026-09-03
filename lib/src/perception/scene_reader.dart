import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart' show Event, InstanceRef, VmService;

import '../runtime/flutter_runtime.dart';
import 'inspector_client.dart';
import 'scene_node.dart';
import 'stable_id.dart';

/// Reads the inspector tree, assigns stable ids, returns a [Scene] the
/// caller disposes when done.
class SceneReader {
  SceneReader(this._inspector, this._runtime);

  final InspectorClient _inspector;
  final FlutterRuntime _runtime;

  /// User-code tree — the agent's reading surface. The full tree is also read
  /// to extract overlay/dialog content, appended to the summary root so
  /// [Scene.findByGlintId] can address those nodes too.
  Future<Scene> readSummary() async {
    final groupName = _inspector.nextReadGroup();
    final root = await _inspector.readSummaryTree(groupName: groupName);

    // Mark offstage IndexedStack children BEFORE id assignment so stable-id
    // generation skips them and firstAddressableId()/hoistPage are unaffected.
    await _markOffstageSubtrees(root, groupName);

    // Before id assignment so overlay nodes get stable ids in the same pass.
    final overlay = await _tryReadOverlay(root);

    StableIdGenerator().assignIds(root);
    return Scene._(
      root: root,
      groupName: groupName,
      inspector: _inspector,
      overlayRoots: overlay?.contentRoots ?? const [],
      hasBarrierOverlay: overlay?.hasBarrier ?? false,
      fullGroupName: overlay?.groupName,
    );
  }

  /// Every framework element. Server-internal only.
  Future<Scene> readFull() async {
    final groupName = _inspector.nextReadGroup();
    final root = await _inspector.readFullTree(groupName: groupName);
    StableIdGenerator().assignIds(root);
    return Scene._(root: root, groupName: groupName, inspector: _inspector);
  }

  // ── offstage pruning (IndexedStack / GoRouter shell routes) ──────────────

  /// Probes hidden-subtree candidates and marks them [SceneNode.isOffstage] so
  /// id assignment, [firstAddressableId], page selection and the classifier
  /// skip them. Candidates: Scaffolds (GoRouter shell branches sit under
  /// `Offstage`) and IndexedStack children (hidden via
  /// `Visibility.maintain(visible:false)` since Flutter 3.7 — never Offstage).
  /// Both wrappers are framework-created and filtered from the summary tree,
  /// so we probe ancestors per candidate rather than detect structurally.
  Future<void> _markOffstageSubtrees(SceneNode root, String groupName) async {
    final candidates = <SceneNode>{
      ...root.walk().where((n) => n.baseLabel == 'Scaffold'),
      ...root
          .walk()
          .where((n) => n.baseLabel == 'IndexedStack')
          .expand((n) => n.children),
    };
    for (final candidate in candidates) {
      if (candidate.inspectorId.isEmpty) continue;
      if (candidate.isOffstage) continue;
      final result = await _runtime.evaluateWithSelection(
        expression:
            '((WidgetInspectorService.instance.selection.currentElement!'
            '.findAncestorWidgetOfExactType<Offstage>()?.offstage ?? false)'
            ' || !(WidgetInspectorService.instance.selection.currentElement!'
            '.findAncestorWidgetOfExactType<Visibility>()?.visible ?? true))'
            '.toString()',
        inspectorId: candidate.inspectorId,
        groupName: groupName,
      );
      if (result == 'true') {
        for (final n in candidate.walk()) {
          n.isOffstage = true;
        }
      }
    }
  }

  // ── overlay ───────────────────────────────────────────────────────────────

  Future<_OverlayResult?> _tryReadOverlay(SceneNode summaryRoot) async {
    // Always read the full tree rather than gating on canPop() — selection
    // .currentElement is unreliable (null above the Navigator), making canPop()
    // throw and silently suppress overlay detection. _extractDialogEntries
    // returns empty for the no-overlay case; the extra read (~50-100ms) is fine
    // since readSummary runs once per tool call, not in a hot loop.
    final fullGroup = _inspector.nextReadGroup();
    final SceneNode fullRoot;
    try {
      fullRoot = await _inspector.readFullTree(groupName: fullGroup);
    } on Object {
      return null;
    }

    final extraction = _extractDialogEntries(fullRoot);

    if (extraction.contentRoots.isEmpty) {
      await _inspector.disposeGroup(fullGroup);
      return null;
    }

    // Append dialog nodes to summary root so findByGlintId reaches them.
    summaryRoot.children.addAll(extraction.contentRoots);

    return _OverlayResult(
      contentRoots: extraction.contentRoots,
      hasBarrier: extraction.hasBarrier,
      groupName: fullGroup,
    );
  }

  /// Walk [fullRoot] to find the [Overlay] widget, then inspect each
  /// [_OverlayEntryWidget] child:
  /// - Entries with a Scaffold descendant → base route, skip.
  /// - Entries with only barrier widgets → modal barrier, skip (sets hasBarrier).
  /// - Everything else → dialog content, include.
  /// First meaningful glintId inside each surfaced dialog entry — the test
  /// seam for overlay classification. Each entry is an [_OverlayEntryWidget]
  /// wrapper, so we dig to the first descendant carrying a glintId.
  @visibleForTesting
  static List<String?> debugOverlayContentIds(SceneNode fullRoot) =>
      _extractDialogEntries(fullRoot).contentRoots
          .map((n) => n.walk().firstWhere((d) => d.glintId != null,
              orElse: () => n).glintId)
          .toList();

  static _DialogExtraction _extractDialogEntries(SceneNode fullRoot) {
    final overlay = _findNode(fullRoot, 'Overlay');
    if (overlay == null) {
      return const _DialogExtraction(contentRoots: [], hasBarrier: false);
    }

    // Flutter 3.x introduced _Theater as an intermediate child of Overlay
    // that groups the overlay entries. Walk into it when present so we reach
    // the actual _OverlayEntryWidget children.
    final entriesParent =
        (overlay.children.firstOrNull?.label == '_Theater')
            ? overlay.children.first
            : overlay;

    final contentRoots = <SceneNode>[];
    var hasBarrier = false;

    for (final entry in entriesParent.children) {
      if (!_isEntryWidget(entry)) continue;
      if (_hasScaffoldDescendant(entry)) continue; // base route
      if (_isTextEditingOverlay(entry)) continue; // cursor handles / toolbar
      if (_isBarrierOnlyEntry(entry)) {
        hasBarrier = true;
        continue;
      }
      contentRoots.add(entry);
    }

    return _DialogExtraction(contentRoots: contentRoots, hasBarrier: hasBarrier);
  }

  static SceneNode? _findNode(SceneNode node, String label) {
    if (node.label == label) return node;
    for (final c in node.children) {
      final f = _findNode(c, label);
      if (f != null) return f;
    }
    return null;
  }

  static bool _isEntryWidget(SceneNode n) {
    final l = n.label;
    return l == '_OverlayEntryWidget' || l == 'OverlayEntry';
  }

  static bool _hasScaffoldDescendant(SceneNode n) =>
      n.walk().any((d) => d.baseLabel == 'Scaffold');

  /// Text-editing overlays — cursor drag handles + the copy/paste toolbar —
  /// ride in their own [OverlayEntry] whenever a field is focused. They are
  /// transient affordances, not modal content: surfacing them as `--- dialog
  /// ---` makes the agent think a modal is open and try to dismiss it.
  static bool _isTextEditingOverlay(SceneNode n) => n.walk().any((d) =>
      const {
        '_SelectionHandleOverlay',
        '_SelectionToolbarWrapper',
        'TextSelectionToolbar',
        'CupertinoTextSelectionToolbar',
        'SelectionContainer',
        'ContextMenu',
      }.contains(d.baseLabel));

  /// True when every descendant is a known barrier/gesture-plumbing widget
  /// with no user-meaningful content.
  static bool _isBarrierOnlyEntry(SceneNode n) {
    // Widgets that are pass-through / pointer-routing plumbing with no
    // user-visible content. MouseRegion appears as an overlay entry in
    // Flutter 3.x for drag/hover tracking — filter it out so it doesn't
    // show up as a spurious `--- dialog ---` section on screens that have
    // no real dialog open.
    const barrierSet = {
      'ModalBarrier',
      'AnimatedModalBarrier',
      '_ModalBarrierGestureDetector',
      'AbsorbPointer',
      'Listener',
      'RawGestureDetector',
      'Semantics',
      'ExcludeSemantics',
      '_OverlayEntryWidget',
      'MouseRegion',
      'Focus',
      'FocusScope',
      'TickerMode',
    };
    return n.walk().skip(1).every((d) => barrierSet.contains(d.label));
  }

}

// ── internal result types ──────────────────────────────────────────────────

class _OverlayResult {
  const _OverlayResult({
    required this.contentRoots,
    required this.hasBarrier,
    required this.groupName,
  });
  final List<SceneNode> contentRoots;
  final bool hasBarrier;
  final String groupName;
}

class _DialogExtraction {
  const _DialogExtraction({
    required this.contentRoots,
    required this.hasBarrier,
  });
  final List<SceneNode> contentRoots;
  final bool hasBarrier;
}

/// One inspector group + its SceneNode tree. Dispose releases the VM-side id table.
class Scene {
  Scene._({
    required this.root,
    required this.groupName,
    required InspectorClient inspector,
    this.overlayRoots = const [],
    this.hasBarrierOverlay = false,
    String? fullGroupName,
  })  : _inspector = inspector,
        _fullGroupName = fullGroupName;

  final SceneNode root;
  final String groupName;
  final InspectorClient _inspector;

  /// Overlay dialog entry nodes (from the full tree). Also appended to
  /// [root.children] so [findByGlintId] and geometry resolution work
  /// without knowing the split.
  final List<SceneNode> overlayRoots;

  /// True when a [ModalBarrier] sits between the topmost overlay and the
  /// base screen — the screen is painted but not hittable.
  final bool hasBarrierOverlay;

  final String? _fullGroupName;

  /// Group name to use when resolving overlay nodes. Overlay nodes' inspectorIds
  /// are allocated in the full-tree group — using the summary group would fail
  /// the Flutter inspector's cross-group object lookup.
  String? get fullGroupName => _fullGroupName;

  bool _disposed = false;

  SceneNode? findByGlintId(String glintId) {
    for (final n in root.walk()) {
      if (n.isOffstage) continue;
      if (n.glintId == glintId) return n;
    }
    return null;
  }

  /// Cheap fingerprint of what the agent can read: labels + text previews in
  /// tree order. Equal signatures across two reads mean nothing readable moved.
  String contentSignature() {
    var hash = 0;
    void mix(String s) {
      for (final c in s.codeUnits) {
        hash = (hash * 31 + c) & 0x7fffffff;
      }
    }

    var count = 0;
    for (final n in root.walk()) {
      if (n.isOffstage) continue;
      count++;
      mix(n.label);
      mix(n.textPreview ?? '');
    }
    return '$count:$hash';
  }

  /// True when [glintId] belongs to an overlay entry (dialog/sheet) rather
  /// than the base screen. The tap tool uses this to warn when a barrier may
  /// intercept the tap.
  bool isInOverlay(String glintId) {
    for (final root in overlayRoots) {
      for (final n in root.walk()) {
        if (n.isOffstage) continue;
        if (n.glintId == glintId) return true;
      }
    }
    return false;
  }

  /// Returns up to 5 candidate nodes for enricher probing.
  ///
  /// Prefers SHALLOW user-code nodes: nodes close to the Scaffold level have
  /// accurate ModalRoute.settings.name. Deep nodes (inside ShellRoute inner
  /// navigators or PageView pages) sit inside nested routes whose settings.name
  /// is null or different from the outer GoRouter path.
  /// [within] restricts the walk to that subtree (e.g. the active page), so
  /// probes can't land on a covered sibling route.
  List<SceneNode> addressableCandidates({int max = 5, SceneNode? within}) {
    final walkRoot = within ?? root;
    final seen = <String>{};
    final result = <SceneNode>[];
    // First pass: shallow (depth ≤ 12) user-code nodes, skipping platform views.
    for (final n in walkRoot.walk().skip(1)) {
      if (result.length >= max) break;
      if (n.isOffstage || n.inspectorId.isEmpty) continue;
      if (n.glintId == null || n.glintId!.isEmpty) continue;
      if (n.isPlatformView) continue;
      if (n.depth > kShallowProbeMaxDepth) continue;
      if (!seen.add(n.inspectorId)) continue;
      if (n.createdByLocalProject) result.add(n);
    }
    // Second pass: any addressable node (deeper fallbacks).
    for (final n in walkRoot.walk().skip(1)) {
      if (result.length >= max) break;
      if (n.isOffstage || n.inspectorId.isEmpty) continue;
      if (n.glintId == null || n.glintId!.isEmpty) continue;
      if (n.isPlatformView) continue;
      if (!seen.add(n.inspectorId)) continue;
      result.add(n);
    }
    return result;
  }

  String? firstAddressableId() {
    // Two-pass: prefer a user-code leaf (createdByLocalProject=true) since
    // platform view plugin nodes (e.g. GoogleMap) fail geometry evals.
    // Fall back to any leaf with a live inspector handle if none found.
    SceneNode? bestUserLeaf;
    SceneNode? bestAnyNode;

    for (final n in root.walk().skip(1)) {
      if (n.isOffstage) continue;
      // Require a live inspector handle — empty inspectorId means setSelection
      // would fail, breaking any enricher that probes geometry or routes.
      if (n.inspectorId.isEmpty) continue;
      if (n.glintId == null || n.glintId!.isEmpty) continue;

      if (n.children.isEmpty && n.isPlatformView) continue;

      if (n.children.isEmpty) {
        if (n.createdByLocalProject) {
          bestUserLeaf ??= n;
        } else {
          bestAnyNode ??= n;
        }
      } else {
        if (n.createdByLocalProject) bestAnyNode ??= n;
      }
    }
    return (bestUserLeaf ?? bestAnyNode)?.glintId;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inspector.disposeGroup(groupName);
    final fullGroup = _fullGroupName;
    if (fullGroup != null) {
      await _inspector.disposeGroup(fullGroup);
    }
  }

  /// Minimal scene for unit tests — no live inspector required.
  factory Scene.forTesting({
    required SceneNode root,
    List<SceneNode> overlayRoots = const [],
    bool hasBarrierOverlay = false,
  }) =>
      Scene._(
        root: root,
        groupName: 'test',
        inspector: _NullInspectorClient(),
        overlayRoots: overlayRoots,
        hasBarrierOverlay: hasBarrierOverlay,
      );

  /// Scene backed by native (OS AX) data rather than the Flutter widget tree.
  /// Dispose is a no-op since there is no inspector group to release.
  factory Scene.native({required SceneNode root}) => Scene._(
        root: root,
        groupName: 'native',
        inspector: _NullInspectorClient(),
      );

  bool get isNative => groupName == 'native';
}

/// No-op inspector used exclusively by [Scene.forTesting].
class _NullInspectorClient extends InspectorClient {
  _NullInspectorClient() : super(_NullRuntime());

  @override
  Future<void> disposeGroup(String groupName) async {}
}

/// Minimal [FlutterRuntime] that does nothing — only used by
/// [_NullInspectorClient] to satisfy the constructor requirement.
class _NullRuntime implements FlutterRuntime {
  @override
  bool get isAttached => false;
  @override
  Uri? get attachedUri => null;
  @override
  Stream<void> get onDisconnect => const Stream.empty();
  @override
  Future<void> attach(Uri vmServiceUri) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<InspectorJson> readWidgetTree({
    required String groupName,
    bool isSummaryTree = true,
    bool withPreviews = true,
    bool fullDetails = false,
  }) =>
      throw UnimplementedError();
  @override
  Future<InspectorJson> readDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> setInspectorSelection({
    required String inspectorId,
    required String groupName,
  }) async {}
  @override
  Future<void> disposeInspectorGroup(String groupName) async {}
  @override
  Future<InstanceRef> evaluate(String expression) => throw UnimplementedError();
  @override
  Future<String?> evaluateString(String expression) async => null;
  @override
  Future<String?> evaluateWithSelection({
    required String expression,
    required String inspectorId,
    required String groupName,
  }) async => null;
  @override
  Stream<Event> get stderrEvents => const Stream.empty();
  @override
  Stream<Event> get stdoutEvents => const Stream.empty();
  @override
  Stream<Event> get loggingEvents => const Stream.empty();
  @override
  VmService get rawService => throw UnimplementedError();
  @override
  String get flutterIsolateId => throw UnimplementedError();
}
