import '../../observability.dart' show StateObserver;
import '../../perception.dart';
import '../../semantic.dart';
import 'envelope.dart';
import 'session.dart';

/// The one scene read a gesture needs: the live [scene] the interactor
/// resolves against, plus the pre-action [pre] snapshot taken from that same
/// read (null when the caller does not want a changed-signal).
class ActionScene {
  ActionScene({required this.scene, this.semantic, this.pre});

  final Scene scene;
  final SemanticScene? semantic;
  final SceneSnapshot? pre;

  Future<void> dispose() => scene.dispose();
}

/// Reads once and, when [snapshot] is set, semanticizes that same read for the
/// pre-action baseline. Replaces the old read-for-snapshot + read-for-action
/// pair every gesture paid.
Future<ActionScene> openActionScene(GlintSession session,
    {required bool snapshot}) async {
  final scene = await session.reader.readSummary();
  if (!snapshot) return ActionScene(scene: scene);
  try {
    final semantic =
        await session.semanticize(scene, detail: SceneDetail.interactive);
    return ActionScene(
      scene: scene,
      semantic: semantic,
      pre: snapshotOf(semantic),
    );
  } on Object {
    await scene.dispose();
    rethrow;
  }
}

/// When [returnScene] and [response] is a success, settle + read the post-action
/// scene and merge {changed, changeCategory, [state], [postScene]} into it. The
/// shared tail every gesture tool ran inline. Returns [response] unchanged in
/// device mode's error/no-scene cases (readPostActionState returns null).
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

/// [SceneSnapshot.from] plus the on-viewport state of each page in a
/// PageView / TabBarView (set by [PagedViewportEnricher]), so a tab switch
/// registers as a change even though the tree is identical before and after.
SceneSnapshot snapshotOf(SemanticScene semantic) {
  final base = SceneSnapshot.from(semantic);
  var hash = base.contentHash;
  void mix(String s) {
    for (final c in s.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
  }

  for (final page in semantic.root.walk().whereType<SemanticPage>()) {
    final on = page.onViewport;
    if (on == null || page.glintId == null) continue;
    mix('${page.glintId}:$on');
  }
  return SceneSnapshot(
    routeName: base.routeName,
    hasOverlay: base.hasOverlay,
    contentHash: hash,
  );
}

/// Detect what category of change occurred between [before] and [after].
String changeCategory(SceneSnapshot before, SceneSnapshot after) {
  if (before.routeName != after.routeName) return 'routeChanged';
  if (!before.hasOverlay && after.hasOverlay) return 'overlayAppeared';
  if (before.hasOverlay && !after.hasOverlay) return 'overlayDismissed';
  if (before.contentHash != after.contentHash) return 'contentChanged';
  return 'nothing';
}

/// Result of a post-action state read: the changed flag, its category, the
/// coarse screen state, an optional scroll displacement, and (only when asked)
/// the rendered scene text.
class PostActionState {
  PostActionState({
    required this.changed,
    required this.changeCategory,
    required this.state,
    this.sceneText,
    this.scrolledPx,
    this.screenshot,
  });

  final bool changed;
  final String changeCategory;

  /// `loaded` / `loading` / `error` from [StateObserver], or `native` when a
  /// native layer took the foreground after the action.
  final String state;

  /// Newest background screenshot when [state] is `native`.
  final String? screenshot;

  /// Set only when the caller passed `includeSceneText: true`; null otherwise
  /// to avoid token-heavy defaults.
  final String? sceneText;

  /// How far the caller's scroll anchor moved, when one was given.
  final double? scrolledPx;

  Map<String, Object?> toData() => {
        'changed': changed,
        'changeCategory': changeCategory,
        if (state != 'loaded') 'state': state,
        if (screenshot != null) 'screenshot': screenshot,
        if (sceneText != null) 'postScene': sceneText,
      };
}

/// Snapshot the scene BEFORE an action fires, for [readPostActionState].
/// Prefer [openActionScene] when the caller also needs the live scene.
Future<SceneSnapshot?> snapshotPreAction(GlintSession session) async {
  try {
    return await session.withScene(
      (semantic) async => snapshotOf(semantic),
      detail: SceneDetail.interactive,
    );
  } on Object {
    return null;
  }
}

/// Reference point inside the primary scrollable, for scroll-displacement
/// detection: (glintId, logicalCenter).
typedef ScrollAnchor = ({String glintId, double x, double y});

/// After an action fires, settle (bounded by `postActionSettleMs`) then read
/// the post-action scene and compare with [pre] for the changed signal. A
/// read that lands on a loading state is retried once so the agent is not
/// handed a spinner. Returns null on error. [includeSceneText] (default false)
/// opts into rendering the full scene text, which is token-heavy.
Future<PostActionState?> readPostActionState(
  GlintSession session,
  SceneSnapshot? pre, {
  bool includeSceneText = false,
  ScrollAnchor? scrollAnchor,
  bool horizontalScroll = false,
}) async {
  try {
    try {
      // A route push/pop animation starts a frame or two AFTER the tap; poll
      // too early and settle catches the idle gap before the animation.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await session.settleDetector.awaitSettle(
        ceilingMs: session.config.postActionSettleMs,
        quietFramesNeeded: session.config.settleQuietFrames,
        checkLoadingAffordances: false,
      );
    } on Object {
      // ignore settle errors — scene read follows regardless
    }
    Future<PostActionState> readOnce() => session.withScene(
          (semantic) async {
            final post = snapshotOf(semantic);
            final category = pre != null ? changeCategory(pre, post) : 'unknown';
            return PostActionState(
              changed: category != 'nothing',
              changeCategory: category,
              state: const StateObserver().observe(semantic).name,
              sceneText: includeSceneText
                  ? const PlainTextSceneRenderer().render(semantic)
                  : null,
              scrolledPx: scrollAnchor == null
                  ? null
                  : await _anchorDisplacement(
                      session, semantic, scrollAnchor, horizontalScroll),
            );
          },
          detail: includeSceneText ? SceneDetail.full : SceneDetail.interactive,
        );
    final app = session.active;
    if (app != null && app.nativeReader != null) {
      await app.refreshSceneMode();
      if (app.sceneMode == SceneMode.native) {
        final capture = app.captures.newest ?? await app.captureNow('lifecycle');
        return PostActionState(
          changed: true,
          changeCategory: 'nativeSurface',
          state: 'native',
          screenshot: capture?.path,
        );
      }
    }
    var state = await readOnce();
    if (state.state == 'loading') {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      state = await readOnce();
    }
    return state;
  } on Object {
    return null;
  }
}

/// How far [anchor] moved along the scroll axis, or null when it is gone or
/// no longer resolvable (e.g. scrolled off a lazy list — the tree-hash
/// detector catches that case instead).
Future<double?> _anchorDisplacement(GlintSession session, SemanticScene semantic,
    ScrollAnchor anchor, bool horizontal) async {
  final scene = semantic.sourceScene;
  if (scene.findByGlintId(anchor.glintId) == null) return null;
  try {
    final c = await session.resolver.resolve(scene, anchor.glintId);
    return horizontal
        ? (c.logicalCenter.x - anchor.x).abs()
        : (c.logicalCenter.y - anchor.y).abs();
  } on Object {
    return null;
  }
}
