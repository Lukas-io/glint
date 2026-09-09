import 'package:glint/glint.dart';
import 'package:glint/src/mcp/post_action.dart';
import 'package:test/test.dart';

import '../perception/fake_scene.dart';

SemanticPage _tab(String id, {required bool onViewport}) => SemanticPage(
      glintId: 'scaffold_in_$id',
      body: [SemanticText(glintId: 'text_in_$id', content: '$id body')],
    )..onViewport = onViewport;

SemanticScene _shell({required String current}) => fakeSemanticScene(
      root: SemanticPage(
        glintId: 'scaffold_in_shell',
        body: [
          SemanticList(glintId: 'page_view', children: [
            _tab('home', onViewport: current == 'home'),
            _tab('search', onViewport: current == 'search'),
          ]),
        ],
      ),
    );

void main() {
  group('paged viewport', () {
    test('the renderer expands the page on the viewport and summarises the rest', () {
      final text = const PlainTextSceneRenderer().render(_shell(current: 'home'));
      expect(text, contains('home body'));
      expect(text, isNot(contains('search body')));
      expect(text, contains('scaffold_in_search'));
    });

    test('onViewport reaches the JSON model', () {
      final json = _tab('home', onViewport: true).toJson();
      expect(json['onViewport'], true);
      expect(SemanticPage(body: const []).toJson().containsKey('onViewport'), false);
    });

    test('a tab switch changes the snapshot even though the tree is identical', () {
      final a = snapshotOf(_shell(current: 'home'));
      final b = snapshotOf(_shell(current: 'search'));
      expect(a.contentHash, isNot(b.contentHash));
    });
  });
}
