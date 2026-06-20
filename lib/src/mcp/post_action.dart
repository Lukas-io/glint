import '../../semantic.dart';
import 'session.dart';

/// Lightweight snapshot of observable scene state for change detection.
class _SceneSnapshot {
  _SceneSnapshot({
    required this.routeName,
    required this.hasOverlay,
    required this.topLevelIdHash,
  });

  final String routeName;
  final bool hasOverlay;
  final int topLevelIdHash;

  factory _SceneSnapshot.from(SemanticScene scene) {
    final route =
        scene.routeStack.isEmpty ? '' : scene.routeStack.first.name;
    final hasOverlay = scene.overlayLayers.isNotEmpty;
    // Hash the set of top-level child glintIds so structural changes register.
    var hash = 0;
    for (final n in scene.root.children) {
      final id = n.glintId ?? n.role.name;
      for (final c in id.codeUnits) {
        hash = (hash * 31 + c) & 0x7fffffff;
      }
    }
    return _SceneSnapshot(
      routeName: route,
      hasOverlay: hasOverlay,
      topLevelIdHash: hash,
    );
  }
}

/// Detect what category of change occurred between [before] and [after].
String _changeCategory(_SceneSnapshot before, _SceneSnapshot after) {
  if (before.routeName != after.routeName) return 'routeChanged';
  if (!before.hasOverlay && after.hasOverlay) return 'overlayAppeared';
  if (before.hasOverlay && !after.hasOverlay) return 'overlayDismissed';
  if (before.topLevelIdHash != after.topLevelIdHash) return 'contentChanged';
  return 'nothing';
}

/// Result of a post-action state read. Includes the new rendered scene text,
/// the changed flag, and the change category.
class PostActionState {
  PostActionState({
    required this.changed,
    required this.changeCategory,
    this.sceneText,
  });

  final bool changed;
  final String changeCategory;
  /// Set only when the caller passed `includeSceneText: true`; null otherwise
  /// to avoid token-heavy defaults.
  final String? sceneText;

  Map<String, Object?> toData() => {
        'changed': changed,
        'changeCategory': changeCategory,
        if (sceneText != null) 'postScene': sceneText,
      };
}

/// Snapshot the scene BEFORE an action fires. Returns an opaque snapshot
/// used by [readPostActionState].
Future<_SceneSnapshot?> snapshotPreAction(GlintSession session) async {
  try {
    final scene = await session.reader.readSummary();
    try {
      final semantic = session.semanticizer.semanticize(scene);
      await session.overlayEnricher.enrich(semantic);
      await session.navEnricher.enrich(semantic);
      return _SceneSnapshot.from(semantic);
    } finally {
      await scene.dispose();
    }
  } on Object {
    return null;
  }
}

/// After an action fires, settle then read the post-action scene and compare
/// with [pre] for the changed signal. Returns null on error. [includeSceneText]
/// (default false) opts into rendering the full scene text, which is token-heavy.
Future<PostActionState?> readPostActionState(
  GlintSession session,
  _SceneSnapshot? pre, {
  bool includeSceneText = false,
}) async {
  try {
    // Settle first (best-effort, don't fail if it times out).
    try {
      await session.settleDetector.awaitSettle();
    } on Object {
      // ignore settle errors — scene read follows regardless
    }

    final scene = await session.reader.readSummary();
    try {
      final semantic = session.semanticizer.semanticize(scene);
      await session.overlayEnricher.enrich(semantic);
      await session.navEnricher.enrich(semantic);
      if (includeSceneText) {
        await session.inputEnricher.enrich(semantic);
        await session.iconEnricher.enrich(semantic);
      }

      final post = _SceneSnapshot.from(semantic);
      final category = pre != null ? _changeCategory(pre, post) : 'unknown';

      return PostActionState(
        changed: category != 'nothing',
        changeCategory: category,
        sceneText: includeSceneText
            ? const PlainTextSceneRenderer().render(semantic)
            : null,
      );
    } finally {
      await scene.dispose();
    }
  } on Object {
    return null;
  }
}
