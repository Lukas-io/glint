import 'package:glint/src/semantic/renderer.dart';
import 'package:glint/src/semantic/semantic_node.dart';
import 'package:glint/src/semantic/semantic_scene.dart';
import 'package:test/test.dart';

import '../perception/fake_scene.dart';

void main() {
  group('overlay-aware scene rendering', () {
    test('no overlay — renders identically to baseline (regression guard)', () {
      final scene = fakeSemanticScene(overlayLayers: []);
      final text = const PlainTextSceneRenderer().render(scene);
      expect(text, isNot(contains('--- dialog ---')));
      expect(text, isNot(contains('--- screen ---')));
      expect(text, isNot(contains('blocked by modal')));
    });

    test('dialog layer renders BEFORE base screen', () {
      final dialogButton = SemanticButton(
        glintId: 'ok_button_in_alert',
        label: 'OK',
      );
      final scene = fakeSemanticScene(
        overlayLayers: [
          SemanticOverlayLayer(
            nodes: [dialogButton],
            isBarriered: true,
          ),
        ],
      );
      final text = const PlainTextSceneRenderer().render(scene);

      final dialogIdx = text.indexOf('--- dialog ---');
      final screenIdx = text.indexOf('--- screen');
      final pageIdx = text.indexOf('page'); // base screen content

      expect(dialogIdx, greaterThanOrEqualTo(0), reason: 'dialog header present');
      expect(screenIdx, greaterThan(dialogIdx), reason: 'screen header after dialog');
      expect(pageIdx, greaterThan(screenIdx), reason: 'base screen content after screen header');
    });

    test('isBarriered=true produces "blocked by modal" annotation on base screen', () {
      final scene = fakeSemanticScene(
        overlayLayers: [
          SemanticOverlayLayer(
            nodes: [SemanticText(glintId: 'msg', content: 'Are you sure?')],
            isBarriered: true,
          ),
        ],
      );
      final text = const PlainTextSceneRenderer().render(scene);
      expect(text, contains('blocked by modal'));
    });

    test('isBarriered=false produces plain screen separator, no blocked annotation', () {
      final scene = fakeSemanticScene(
        overlayLayers: [
          SemanticOverlayLayer(
            nodes: [SemanticText(glintId: 'msg', content: 'hint')],
            isBarriered: false,
          ),
        ],
      );
      final text = const PlainTextSceneRenderer().render(scene);
      expect(text, contains('--- screen ---'));
      expect(text, isNot(contains('blocked by modal')));
    });

    test('multiple overlay layers render in topmost-first order', () {
      final scene = fakeSemanticScene(
        overlayLayers: [
          SemanticOverlayLayer(
            nodes: [SemanticText(glintId: 'top', content: 'top-dialog')],
            isBarriered: true,
            kind: 'dialog',
          ),
          SemanticOverlayLayer(
            nodes: [SemanticText(glintId: 'inner', content: 'inner-sheet')],
            isBarriered: false,
            kind: 'bottomSheet',
          ),
        ],
      );
      final text = const PlainTextSceneRenderer().render(scene);

      final top = text.indexOf('top-dialog');
      final inner = text.indexOf('inner-sheet');
      expect(top, greaterThanOrEqualTo(0));
      expect(inner, greaterThan(top), reason: 'topmost layer content appears first');
    });

    test('SemanticOverlayLayer.toJson includes kind, isBarriered, nodes', () {
      final layer = SemanticOverlayLayer(
        nodes: [SemanticText(glintId: 't', content: 'hello')],
        isBarriered: true,
        kind: 'bottomSheet',
      );
      final j = layer.toJson();
      expect(j['kind'], 'bottomSheet');
      expect(j['isBarriered'], true);
      expect(j['nodes'], isA<List>());
    });

    test('SemanticOverlayLayer.toJson omits isBarriered when false', () {
      final layer = SemanticOverlayLayer(nodes: [], isBarriered: false);
      final j = layer.toJson();
      expect(j.containsKey('isBarriered'), isFalse);
    });

    test('SemanticScene.toJson carries overlayLayers so json mode is not '
        'blind to dialogs', () {
      final scene = fakeSemanticScene(
        overlayLayers: [
          SemanticOverlayLayer(
            nodes: [SemanticButton(glintId: 'ok_button', label: 'OK')],
            isBarriered: true,
            kind: 'dialog',
          ),
        ],
      );
      final j = scene.toJson();
      final layers = j['overlayLayers'] as List;
      expect(layers, hasLength(1));
      final layer = layers.first as Map;
      expect(layer['kind'], 'dialog');
      final nodes = layer['nodes'] as List;
      expect((nodes.first as Map)['glintId'], 'ok_button');
    });

    test('SemanticScene.toJson omits overlayLayers when none are present', () {
      final scene = fakeSemanticScene(overlayLayers: []);
      expect(scene.toJson().containsKey('overlayLayers'), isFalse);
    });
  });
}
