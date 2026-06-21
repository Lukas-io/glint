import 'package:glint/src/observability/state_observer.dart';
import 'package:glint/src/semantic/semantic_node.dart';
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
