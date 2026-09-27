import 'package:glint_mcp/perception.dart';
import 'package:glint_mcp/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

InstanceRef _ref(String id, [String? value]) => InstanceRef(
      id: id,
      kind: InstanceKind.kString,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'String', library: null),
      valueAsString: value,
    );

/// Answers the geometry, clip and three hit-test evals the way a live app does.
class _Runtime implements FlutterRuntime {
  _Runtime({required this.verdict, this.clip = ''});
  final String verdict;
  final String clip;
  final evalInCalls = <(String?, Map<String, String>?)>[];

  @override
  Future<void> setInspectorSelection(
      {required String inspectorId, required String groupName}) async {}

  @override
  Future<String?> evaluateString(String expression,
      {bool rethrowErrors = false}) async {
    if (expression == GeometryExpr.clip) return clip;
    return '{"gx":48,"gy":400,"bx":0,"by":0,"bw":48,"bh":48,"dpr":2.625,'
        '"vw":411,"vh":914,"op":1.0,"vis":true,"hit":true,"vid":0,"kb":0}';
  }

  @override
  Future<InstanceRef> evaluateIn(String expression,
      {String? librarySuffix, Map<String, String>? scope}) async {
    evalInCalls.add((librarySuffix, scope));
    if (expression == GeometryExpr.hitInputs) return _ref('pair');
    if (librarySuffix == GeometryExpr.gesturesLibrary) return _ref('path');
    return _ref('verdict', verdict);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

SceneNode _node(String label,
        {String? glintId, String? text, List<SceneNode> children = const []}) =>
    SceneNode(
      depth: 1,
      indexInParent: 0,
      description: label,
      type: '_Element',
      inspectorId: 'i-${glintId ?? label}',
      widgetRuntimeType: label,
      glintId: glintId,
      textPreview: text,
      children: children,
    );

void main() {
  final scene = Scene.forTesting(
    root: _node('Column', glintId: 'column', children: [
      _node('Checkbox', glintId: 'checkbox'),
      _node('InkWell', glintId: 'continue_button', children: [
        _node('Text', glintId: 'text', text: 'Continue'),
      ]),
    ]),
  );

  test('a hit on the target is real and hittable', () async {
    final rt = _Runtime(verdict: 'hit');
    final c = await CoordinateResolver(rt).resolve(scene, 'checkbox');
    expect(c.hittable, isTrue);
    expect(c.hitTestReal, isTrue);
    expect(rt.evalInCalls[1].$1, GeometryExpr.gesturesLibrary);
    expect(rt.evalInCalls[1].$2, {'x': 'pair'});
    expect(rt.evalInCalls[2].$2, {'h': 'path'});
  });

  test('a miss names the nearest scene node on the winner chain, with its text', () async {
    final rt = _Runtime(verdict: 'miss:Listener|i-x,i-continue_button,i-column');
    final c = await CoordinateResolver(rt).resolve(scene, 'checkbox');
    expect(c.hittable, isFalse);
    expect(c.hitBy, 'continue_button "Continue"');
    expect(c.warnings.join(), contains('continue_button'));
  });

  test('a miss outside the scene falls back to the winner widget type', () async {
    final rt = _Runtime(verdict: 'miss:Listener|i-x');
    final c = await CoordinateResolver(rt).resolve(scene, 'checkbox');
    expect(c.hitBy, 'Listener');
  });

  test('a centre outside the scroll viewport is not on the viewport', () async {
    final rt = _Runtime(verdict: 'hit', clip: '0,102,411,250');
    final c = await CoordinateResolver(rt).resolve(scene, 'checkbox');
    expect(c.clip, (x: 0.0, y: 102.0, w: 411.0, h: 250.0));
    expect(c.centerInClip, isFalse);
    expect(c.centerOnViewport, isFalse);
  });
}
