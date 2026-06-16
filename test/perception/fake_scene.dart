import 'package:glint/src/perception/scene_node.dart';
import 'package:glint/src/perception/scene_reader.dart';
import 'package:glint/src/semantic/semantic_node.dart';
import 'package:glint/src/semantic/semantic_scene.dart';

/// Build a minimal [SemanticScene] suitable for unit-testing the renderer
/// and enrichers. [sourceScene] is a no-op [Scene] backed by a null runtime.
SemanticScene fakeSemanticScene({
  SemanticNode? root,
  List<SemanticOverlayLayer> overlayLayers = const [],
}) {
  final sceneRoot = SceneNode(
    depth: 0,
    indexInParent: -1,
    description: 'Scaffold',
    type: '_Element',
    inspectorId: 'i-root',
    widgetRuntimeType: 'Scaffold',
    children: [],
  );
  final fakeRoot = root ??
      SemanticPage(
        glintId: 'page',
        appBar: null,
        body: [],
      );
  return SemanticScene(
    root: fakeRoot,
    sourceScene: Scene.forTesting(root: sceneRoot),
    overlayLayers: overlayLayers,
  );
}
