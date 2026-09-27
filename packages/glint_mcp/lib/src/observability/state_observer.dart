import '../../perception.dart' show kLoadingAffordanceLabels;
import '../../semantic.dart';

/// Coarse top-level state per §8.6: derived cheaply from the already-
/// read scene. No extra polling — just inspects what's there.
enum SceneState { loaded, loading, error }

class StateObserver {
  const StateObserver();

  // A build that throws renders one of these instead of the widget — a
  // true error signal with no false positives. Heuristic error detection
  // (banner / SnackBar text) stays deferred; too noisy to be trustworthy.
  static const _errorLabels = {'ErrorWidget', 'RenderErrorBox'};

  SceneState observe(SemanticScene scene) {
    // Error wins over loading — a crashed build outranks a spinner.
    var loading = false;
    for (final label in _labels(scene)) {
      if (_errorLabels.contains(label)) return SceneState.error;
      if (kLoadingAffordanceLabels.contains(label)) loading = true;
    }
    return loading ? SceneState.loading : SceneState.loaded;
  }

  /// Unknown semantic nodes plus every raw widget on the active page and in overlays, so a spinner folded into a button still counts.
  Iterable<String> _labels(SemanticScene scene) sync* {
    for (final n in scene.root.walk()) {
      if (n is SemanticUnknown) yield n.label;
    }
    final id = scene.root.glintId;
    final page = id == null ? null : scene.sourceFor(id);
    for (final root in [if (page != null) page, ...scene.sourceScene.overlayRoots]) {
      for (final n in root.walk()) {
        if (!n.isOffstage) yield n.baseLabel;
      }
    }
  }
}
