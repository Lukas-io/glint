import 'package:glint/src/perception/scene_node.dart';
import 'package:glint/src/perception/scene_reader.dart';
import 'package:test/test.dart';

SceneNode _n(String label, {String? glintId, List<SceneNode> children = const []}) {
  return SceneNode(
    depth: 0,
    indexInParent: -1,
    description: label,
    type: '_Element',
    inspectorId: 'i-$label',
    widgetRuntimeType: label,
    glintId: glintId,
    children: children,
  );
}

/// Wrap entries under Overlay > _Theater as the live tree does.
SceneNode _overlayTree(List<SceneNode> entries) =>
    _n('Overlay', children: [_n('_Theater', children: entries)]);

SceneNode _entry(List<SceneNode> children) =>
    _n('_OverlayEntryWidget', children: children);

void main() {
  group('overlay extraction', () {
    test('a real dialog entry is surfaced', () {
      final tree = _overlayTree([
        _entry([_n('Scaffold')]), // base route
        _entry([
          _n('AlertDialog', glintId: 'alert', children: [
            _n('TextButton', glintId: 'ok_button'),
          ]),
        ]),
      ]);
      expect(SceneReader.debugOverlayContentIds(tree), ['alert']);
    });

    test('text-selection handle overlay is NOT a dialog', () {
      final tree = _overlayTree([
        _entry([_n('Scaffold')]),
        _entry([
          _n('_SelectionHandleOverlay', glintId: 'handle', children: [
            _n('CustomPaint', glintId: 'custom_paint'),
          ]),
        ]),
      ]);
      expect(SceneReader.debugOverlayContentIds(tree), isEmpty,
          reason: 'cursor drag handle is a text-editing affordance, not a modal');
    });

    test('selection toolbar overlay is NOT a dialog', () {
      final tree = _overlayTree([
        _entry([
          _n('TextSelectionToolbar', glintId: 'toolbar', children: [
            _n('TextButton', glintId: 'copy'),
          ]),
        ]),
      ]);
      expect(SceneReader.debugOverlayContentIds(tree), isEmpty);
    });

    test('a dialog still surfaces even when a selection overlay is also open', () {
      final tree = _overlayTree([
        _entry([_n('Scaffold')]),
        _entry([_n('_SelectionHandleOverlay', glintId: 'handle')]),
        _entry([
          _n('Dialog', glintId: 'confirm', children: [
            _n('Text'),
          ]),
        ]),
      ]);
      expect(SceneReader.debugOverlayContentIds(tree), ['confirm']);
    });

    test('barrier-only entry is not surfaced as content', () {
      final tree = _overlayTree([
        _entry([_n('ModalBarrier')]),
      ]);
      expect(SceneReader.debugOverlayContentIds(tree), isEmpty);
    });
  });
}
