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

  // A build that throws renders one of these instead of the widget — a
  // true error signal with no false positives. Heuristic error detection
  // (banner / SnackBar text) stays deferred; too noisy to be trustworthy.
  static const _errorLabels = {'ErrorWidget', 'RenderErrorBox'};

  SceneState observe(SemanticScene scene) {
    // We only see SemanticNodes here; loading/error affordances were
    // classified as SemanticUnknown (no specific role). Check by label.
    // Error wins over loading — a crashed build outranks a spinner.
    var loading = false;
    for (final n in scene.root.walk()) {
      if (n is! SemanticUnknown) continue;
      if (_errorLabels.contains(n.label)) return SceneState.error;
      if (_loadingLabels.contains(n.label)) loading = true;
    }
    return loading ? SceneState.loading : SceneState.loaded;
  }
}
