import 'package:glint/glint.dart';
import 'package:glint/src/mcp/post_action.dart';
import 'package:test/test.dart';

SemanticScene _scene(SemanticNode root,
    {List<RouteFrame> routes = const [],
    List<SemanticOverlayLayer> overlays = const []}) {
  final s = SemanticScene(root: root, sourceScene: _FakeScene());
  s.routeStack = routes;
  s.overlayLayers = overlays;
  return s;
}

void main() {
  group('SceneSnapshot change detection', () {
    test('identical scenes report nothing', () {
      SemanticNode build() => SemanticPage(body: [
            SemanticText(glintId: 't', content: 'hello'),
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(build())),
        SceneSnapshot.from(_scene(build())),
      );
      expect(cat, 'nothing');
    });

    test('deep text change reports contentChanged', () {
      SemanticNode build(String s) => SemanticPage(body: [
            SemanticContainer(hint: 'column', children: [
              SemanticContainer(hint: 'row', children: [
                SemanticText(glintId: 'counter', content: s),
              ]),
            ]),
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(build('0'))),
        SceneSnapshot.from(_scene(build('1'))),
      );
      expect(cat, 'contentChanged');
    });

    test('toggle state flip reports contentChanged', () {
      SemanticNode build(String state) => SemanticPage(body: [
            SemanticButton(glintId: 'checkbox', isToggle: true)
              ..toggleState = state,
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(build('on'))),
        SceneSnapshot.from(_scene(build('off'))),
      );
      expect(cat, 'contentChanged');
    });

    test('input value change reports contentChanged', () {
      SemanticNode build(String v) => SemanticPage(body: [
            SemanticInput(glintId: 'email')..currentValue = v,
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(build('a'))),
        SceneSnapshot.from(_scene(build('ab'))),
      );
      expect(cat, 'contentChanged');
    });

    test('subtree swap deep in the page reports contentChanged', () {
      SemanticNode build(String tab) => SemanticPage(body: [
            SemanticContainer(hint: 'stack', children: [
              SemanticText(glintId: 'text_in_$tab', content: tab),
            ]),
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(build('profile'))),
        SceneSnapshot.from(_scene(build('qr'))),
      );
      expect(cat, 'contentChanged');
    });

    test('icon enrichment difference does NOT report a change', () {
      SemanticNode plain() => SemanticPage(body: [SemanticIcon(glintId: 'i')]);
      SemanticNode enriched() => SemanticPage(body: [
            SemanticIcon(glintId: 'i')
              ..name = 'home'
              ..codePoint = 0xe88a,
          ]);
      final cat = changeCategory(
        SceneSnapshot.from(_scene(plain())),
        SceneSnapshot.from(_scene(enriched())),
      );
      expect(cat, 'nothing');
    });

    test('route change wins over content change', () {
      final before = SceneSnapshot.from(_scene(
        SemanticPage(body: [SemanticText(glintId: 't', content: 'a')]),
        routes: [RouteFrame(name: '/home', isModal: false)],
      ));
      final after = SceneSnapshot.from(_scene(
        SemanticPage(body: [SemanticText(glintId: 't', content: 'b')]),
        routes: [RouteFrame(name: '/details', isModal: false)],
      ));
      expect(changeCategory(before, after), 'routeChanged');
    });

    test('overlay content change reports contentChanged', () {
      SemanticScene build(String label) => _scene(
            SemanticPage(body: [SemanticText(glintId: 't', content: 'base')]),
            overlays: [
              SemanticOverlayLayer(
                nodes: [SemanticText(glintId: 'd', content: label)],
                isBarriered: true,
                kind: 'dialog',
              ),
            ],
          );
      final cat = changeCategory(
        SceneSnapshot.from(build('Loading…')),
        SceneSnapshot.from(build('Done')),
      );
      expect(cat, 'contentChanged');
    });
  });
}

/// Bare scene stub — snapshot code never touches the source scene.
class _FakeScene implements Scene {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
