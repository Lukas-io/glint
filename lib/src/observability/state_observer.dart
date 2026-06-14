import '../../semantic.dart';

/// Coarse top-level state per §8.6: derived cheaply from the already-
/// read scene. No extra polling — just inspects what's there.
enum SceneState { loaded, loading, error }

class StateObserver {
  const StateObserver();

  static const _loadingLabels = {
    'CircularProgressIndicator',
    'LinearProgressIndicator',
    'RefreshIndicator',
    'CupertinoActivityIndicator',
  };

  SceneState observe(SemanticScene scene) {
    // We only see SemanticNodes here; loading affordances were
    // classified as SemanticUnknown (no specific role). Check by label.
    for (final n in scene.root.walk()) {
      if (n is SemanticUnknown && _loadingLabels.contains(n.label)) {
        return SceneState.loading;
      }
    }
    // Error detection (banner / SnackBar etc.) is deferred to v1.
    return SceneState.loaded;
  }
}
