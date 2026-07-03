import '../../semantic.dart';
import 'envelope.dart';
import 'session.dart';

/// When [returnScene] and [response] is a success, settle + read the post-action
/// scene and merge {changed, changeCategory, [postScene]} into it. The shared
/// tail every gesture tool ran inline. Returns [response] unchanged in device
/// mode's error/no-scene cases (readPostActionState returns null).
Future<StructuredResponse> appendPostAction(
  GlintSession session,
  StructuredResponse response,
  SceneSnapshot? pre, {
  required bool returnScene,
  required bool fetchScene,
}) async {
  if (!returnScene || response.isError) return response;
  final post =
      await readPostActionState(session, pre, includeSceneText: fetchScene);
  return post == null ? response : response.mergeData(post.toData());
}

/// Lightweight snapshot of observable scene state for change detection.
class SceneSnapshot {
  SceneSnapshot({
    required this.routeName,
    required this.hasOverlay,
    required this.contentHash,
  });

  final String routeName;
  final bool hasOverlay;
  final int contentHash;

  /// Hashes the WHOLE tree (id, role, text, input value, button label/toggle)
  /// plus overlay content — a deep change (tab swap, text edit, toggle flip)
  /// must register, not just top-level structure.
  factory SceneSnapshot.from(SemanticScene scene) {
    final route =
        scene.routeStack.isEmpty ? '' : scene.routeStack.first.name;
    final hasOverlay = scene.overlayLayers.isNotEmpty;
    var hash = 0;
    void mix(String s) {
      for (final c in s.codeUnits) {
        hash = (hash * 31 + c) & 0x7fffffff;
      }
    }

    // Icon names are deliberately excluded: they only resolve at full detail,
    // so hashing them would fake a change between detail levels.
    void mixTree(SemanticNode root) {
      for (final n in root.walk()) {
        mix(n.glintId ?? '');
        mix(n.role.name);
        if (n is SemanticText) mix(n.content);
        if (n is SemanticInput) {
          mix(n.currentValue ?? '');
          mix(n.hint ?? '');
          mix(n.error ?? '');
        }
        if (n is SemanticButton) {
          mix(n.label ?? '');
          mix(n.toggleState ?? '');
        }
      }
    }

    mixTree(scene.root);
    for (final layer in scene.overlayLayers) {
      layer.nodes.forEach(mixTree);
    }
    return SceneSnapshot(
      routeName: route,
      hasOverlay: hasOverlay,
      contentHash: hash,
    );
  }
}

/// Detect what category of change occurred between [before] and [after].
String changeCategory(SceneSnapshot before, SceneSnapshot after) {
  if (before.routeName != after.routeName) return 'routeChanged';
  if (!before.hasOverlay && after.hasOverlay) return 'overlayAppeared';
  if (before.hasOverlay && !after.hasOverlay) return 'overlayDismissed';
  if (before.contentHash != after.contentHash) return 'contentChanged';
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

/// Snapshot the scene BEFORE an action fires, for [readPostActionState].
Future<SceneSnapshot?> snapshotPreAction(GlintSession session) async {
  try {
    return await session.withScene(
      (semantic) async => SceneSnapshot.from(semantic),
      detail: SceneDetail.interactive,
    );
  } on Object {
    return null;
  }
}

/// After an action fires, settle then read the post-action scene and compare
/// with [pre] for the changed signal. Returns null on error. [includeSceneText]
/// (default false) opts into rendering the full scene text, which is token-heavy.
Future<PostActionState?> readPostActionState(
  GlintSession session,
  SceneSnapshot? pre, {
  bool includeSceneText = false,
}) async {
  try {
    // Settle first (best-effort, don't fail if it times out).
    try {
      // Let the action's effect begin before polling for idle. A route
      // push/pop animation starts a frame or two AFTER the tap; without this
      // pause settle can catch the brief idle gap before the animation and
      // read a mid-transition scene — reporting a real navigation as
      // changed:false.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await session.settleDetector.awaitSettle();
    } on Object {
      // ignore settle errors — scene read follows regardless
    }
    return await session.withScene(
      (semantic) async {
        final post = SceneSnapshot.from(semantic);
        final category = pre != null ? changeCategory(pre, post) : 'unknown';
        return PostActionState(
          changed: category != 'nothing',
          changeCategory: category,
          sceneText: includeSceneText
              ? const PlainTextSceneRenderer().render(semantic)
              : null,
        );
      },
      detail: includeSceneText ? SceneDetail.full : SceneDetail.interactive,
    );
  } on Object {
    return null;
  }
}
