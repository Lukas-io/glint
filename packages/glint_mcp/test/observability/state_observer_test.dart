import 'package:glint_mcp/src/observability/state_observer.dart';
import 'package:glint_mcp/src/perception/scene_node.dart';
import 'package:glint_mcp/src/perception/scene_reader.dart';
import 'package:glint_mcp/src/semantic/semantic_node.dart';
import 'package:glint_mcp/src/semantic/semantic_scene.dart';
import 'package:test/test.dart';

import '../perception/fake_scene.dart';

SemanticNode _pageWith(List<SemanticNode> body) =>
    SemanticPage(glintId: 'page', appBar: null, body: body);

void main() {
  group('StateObserver', () {
    const observer = StateObserver();

    test('plain content → loaded', () {
      final scene = fakeSemanticScene(
        root: _pageWith([SemanticText(glintId: 't', content: 'hi')]),
      );
      expect(observer.observe(scene), SceneState.loaded);
    });

    test('spinner present → loading', () {
      final scene = fakeSemanticScene(
        root: _pageWith([
          SemanticUnknown(
            glintId: 's',
            label: 'CircularProgressIndicator',
          ),
        ]),
      );
      expect(observer.observe(scene), SceneState.loading);
    });

    test('a spinner folded into a button still counts as loading', () {
      final spinner = SceneNode(
        depth: 2,
        indexInParent: 0,
        description: 'CircularProgressIndicator',
        type: '_Element',
        inspectorId: 'i-spin',
        widgetRuntimeType: 'CircularProgressIndicator',
      );
      final page = SceneNode(
        depth: 0,
        indexInParent: -1,
        description: 'Scaffold',
        type: '_Element',
        inspectorId: 'i-page',
        widgetRuntimeType: 'Scaffold',
        children: [
          SceneNode(
            depth: 1,
            indexInParent: 0,
            description: 'InkWell',
            type: '_Element',
            inspectorId: 'i-btn',
            widgetRuntimeType: 'InkWell',
            children: [spinner],
          ),
        ],
      )..glintId = 'page';
      final scene = SemanticScene(
        root: SemanticPage(glintId: 'page', appBar: null, body: [
          SemanticButton(glintId: 'create', label: 'Create account'),
        ]),
        sourceScene: Scene.forTesting(root: page),
      );
      expect(observer.observe(scene), SceneState.loading);
    });

    test('ErrorWidget present → error', () {
      final scene = fakeSemanticScene(
        root: _pageWith([
          SemanticUnknown(glintId: 'e', label: 'ErrorWidget'),
        ]),
      );
      expect(observer.observe(scene), SceneState.error);
    });

    test('error outranks loading when both present', () {
      final scene = fakeSemanticScene(
        root: _pageWith([
          SemanticUnknown(glintId: 's', label: 'CircularProgressIndicator'),
          SemanticUnknown(glintId: 'e', label: 'RenderErrorBox'),
        ]),
      );
      expect(observer.observe(scene), SceneState.error);
    });
  });
}
