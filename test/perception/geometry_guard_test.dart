import 'package:glint/perception.dart';
import 'package:glint/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';

class _ProseRuntime implements FlutterRuntime {
  _ProseRuntime(this.reply);
  final String reply;

  @override
  Future<void> setInspectorSelection(
          {required String inspectorId, required String groupName}) async {}

  @override
  Future<String?> evaluateString(String expression) async => reply;

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

SceneNode _node(String glintId) => SceneNode(
      depth: 1,
      indexInParent: 0,
      description: 'Text',
      type: '_Element',
      inspectorId: 'i-$glintId',
      widgetRuntimeType: 'Text',
      glintId: glintId,
    );

void main() {
  group('CoordinateResolver eval decoding', () {
    test('a non-JSON eval reply is a GeometryResolveError, not a crash',
        () async {
      final resolver = CoordinateResolver(_ProseRuntime("Instance of 'Offset'"));
      final scene = Scene.forTesting(root: _node('label'));
      await expectLater(
        resolver.resolve(scene, 'label'),
        throwsA(isA<GeometryResolveError>().having(
            (e) => e.message, 'message', contains('non-JSON'))),
      );
    });

    test('node-free viewport probe decodes the implicit view blob', () async {
      final resolver =
          CoordinateResolver(_ProseRuntime('{"dpr":3,"vw":420,"vh":912}'));
      final v = await resolver.resolveViewportNodeFree();
      expect(v.dpr, 3);
      expect(v.w, 420);
      expect(v.h, 912);
    });

    test('node-free viewport probe surfaces prose as a typed error', () async {
      final resolver = CoordinateResolver(_ProseRuntime('<collected>'));
      await expectLater(
        resolver.resolveViewportNodeFree(),
        throwsA(isA<GeometryResolveError>()),
      );
    });
  });
}
