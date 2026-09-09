import 'package:glint/perception.dart';
import 'package:glint/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';

/// Returns a fixed geometry blob (hit:true) so the test isolates the
/// scene-level barrier fold-in from the eval.
class _FakeRuntime implements FlutterRuntime {
  @override
  Future<void> setInspectorSelection(
          {required String inspectorId, required String groupName}) async {}
  @override
  Future<String?> evaluateString(String expression) async =>
      '{"gx":100,"gy":200,"bx":0,"by":0,"bw":40,"bh":40,"dpr":2,'
      '"vw":400,"vh":800,"op":1.0,"vis":true,"hit":true}';
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

SceneNode _node(String glintId, {List<SceneNode> children = const []}) =>
    SceneNode(
      depth: 1,
      indexInParent: 0,
      description: 'ElevatedButton',
      type: '_Element',
      inspectorId: 'i-$glintId',
      widgetRuntimeType: 'ElevatedButton',
      glintId: glintId,
      children: children,
    );

void main() {
  group('hittable folds in a ModalBarrier', () {
    final resolver = CoordinateResolver(_FakeRuntime());

    test('base-tree node under a barrier is NOT hittable (eval said hit:true)',
        () async {
      final scene = Scene.forTesting(
        root: _node('base_button'),
        hasBarrierOverlay: true,
      );
      final c = await resolver.resolve(scene, 'base_button');
      expect(c.hittable, isFalse,
          reason: 'a modal barrier covers the base screen');
    });

    test('same node is hittable when no barrier is up', () async {
      final scene = Scene.forTesting(root: _node('base_button'));
      final c = await resolver.resolve(scene, 'base_button');
      expect(c.hittable, isTrue);
    });

    test('an overlay-layer node stays hittable even with a barrier', () async {
      // Real scenes append overlay entries to the root tree too, so
      // findByGlintId resolves them; isInOverlay keys off overlayRoots.
      final dialogNode = _node('ok_in_dialog');
      final scene = Scene.forTesting(
        root: _node('root', children: [_node('base_button'), dialogNode]),
        overlayRoots: [dialogNode],
        hasBarrierOverlay: true,
      );
      final c = await resolver.resolve(scene, 'ok_in_dialog');
      expect(c.hittable, isTrue,
          reason: 'the dialog sits above the barrier, not under it');
    });
  });
}
