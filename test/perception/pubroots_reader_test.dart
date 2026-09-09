import 'package:glint/src/perception/inspector_client.dart';
import 'package:glint/src/perception/scene_reader.dart';
import 'package:glint/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show InstanceRef, VmService;

/// A runtime that serves a fixed inspector tree and records pub-root registrations.
class _StubRuntime implements FlutterRuntime {
  _StubRuntime(this.tree, {this.rootDir = '/Users/x/app'});

  final Map<String, Object?> tree;
  final String? rootDir;
  final List<List<String>> pubRootCalls = [];
  int appRootReads = 0;

  @override
  Future<Map<String, Object?>> readWidgetTree({
    required String groupName,
    bool isSummaryTree = true,
    bool withPreviews = true,
    bool fullDetails = false,
  }) async =>
      isSummaryTree ? tree : {'description': 'RootWidget', 'children': []};

  @override
  Future<String?> appRootDirectory() async {
    appRootReads++;
    return rootDir;
  }

  @override
  Future<void> setPubRootDirectories(List<String> dirs) async =>
      pubRootCalls.add(dirs);

  @override
  Future<void> disposeInspectorGroup(String groupName) async {}

  @override
  Future<String?> evaluateWithSelection({
    required String expression,
    required String inspectorId,
    required String groupName,
  }) async =>
      'false';

  // Unused by readSummary.
  @override
  Stream<void> get onDisconnect => const Stream.empty();
  @override
  bool get isAttached => true;
  @override
  Uri? get attachedUri => null;
  @override
  Future<void> attach(Uri vmServiceUri) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<Map<String, Object?>> readDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) async =>
      {};
  @override
  Future<void> setInspectorSelection(
      {required String inspectorId, required String groupName}) async {}
  @override
  Future<InstanceRef> evaluate(String expression) => throw UnimplementedError();
  @override
  Future<String?> evaluateString(String expression) async => null;
  @override
  VmService get rawService => throw UnimplementedError();
  @override
  String get flutterIsolateId => 'iso-1';
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

Map<String, Object?> _leaf(String desc, {bool local = false}) => {
      'description': desc,
      'type': 'x',
      'valueId': 'v-$desc',
      'createdByLocalProject': local,
      'children': <Object?>[],
    };

void main() {
  group('SceneReader pub roots', () {
    test('registers the app root once, on the first read', () async {
      final rt = _StubRuntime({
        'description': 'RootWidget',
        'children': [_leaf('MyForm', local: true)],
      });
      final reader = SceneReader(InspectorClient(rt), rt);

      final a = await reader.readSummary();
      final b = await reader.readSummary();

      expect(rt.pubRootCalls, [
        ['/Users/x/app'],
      ]);
      expect(rt.appRootReads, 1);
      expect(a.degenerate, isFalse);
      expect(b.degenerate, isFalse);
    });

    test('flags a tree with no app widgets as degenerate', () async {
      final rt = _StubRuntime({
        'description': 'RootWidget',
        'children': [_leaf('MaterialApp')],
      });
      final scene = await SceneReader(InspectorClient(rt), rt).readSummary();
      expect(scene.degenerate, isTrue);
    });

    test('a null app root skips registration without throwing', () async {
      final rt = _StubRuntime(
        {
          'description': 'RootWidget',
          'children': [_leaf('MyForm', local: true)],
        },
        rootDir: null,
      );
      final scene = await SceneReader(InspectorClient(rt), rt).readSummary();
      expect(rt.pubRootCalls, isEmpty);
      expect(scene.degenerate, isFalse);
    });
  });
}
