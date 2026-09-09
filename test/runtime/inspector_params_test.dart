import 'package:glint/src/perception/scene_node.dart';
import 'package:glint/src/runtime/inspector_params.dart';
import 'package:test/test.dart';

SceneNode _n(String desc,
        {bool local = false, List<SceneNode> children = const []}) =>
    SceneNode(
      depth: 0,
      indexInParent: 0,
      description: desc,
      type: '',
      inspectorId: 'id-$desc',
      createdByLocalProject: local,
      children: children,
    );

void main() {
  group('InspectorParams', () {
    test('disposeGroup sends objectGroup, not groupName', () {
      expect(InspectorParams.disposeGroup('g5'), {'objectGroup': 'g5'});
    });

    test('the tree read keeps groupName and stringifies the flags', () {
      expect(
        InspectorParams.rootWidgetTree(groupName: 'g1', isSummaryTree: true),
        {
          'groupName': 'g1',
          'isSummaryTree': 'true',
          'withPreviews': 'true',
          'fullDetails': 'false',
        },
      );
    });

    test('detailsSubtree and selectionById use objectGroup + arg', () {
      expect(InspectorParams.detailsSubtree(inspectorId: 'x', groupName: 'g'),
          {'arg': 'x', 'objectGroup': 'g', 'subtreeDepth': '5'});
      expect(InspectorParams.selectionById(inspectorId: 'x', groupName: 'g'),
          {'arg': 'x', 'objectGroup': 'g'});
    });

    test('pubRootDirectories are var-args arg0, arg1, …', () {
      expect(InspectorParams.pubRootDirectories(['/a', '/b']),
          {'arg0': '/a', 'arg1': '/b'});
      expect(InspectorParams.pubRootDirectories(const []), isEmpty);
    });
  });

  group('appRootFromMainScript', () {
    test('strips /lib/main.dart to the package root', () {
      expect(appRootFromMainScript('file:///Users/x/app/lib/main.dart'),
          '/Users/x/app');
    });

    test('handles a path under packages/flutter/', () {
      expect(
          appRootFromMainScript(
              'file:///Users/x/packages/flutter/counter/lib/main.dart'),
          '/Users/x/packages/flutter/counter');
    });

    test('null and no-lib return null', () {
      expect(appRootFromMainScript(null), isNull);
      expect(appRootFromMainScript('file:///Users/x/app/bin/tool.dart'), isNull);
    });
  });

  group('isDegenerateTree', () {
    test('true when nothing below the root is local-project', () {
      final root = _n('RootWidget', children: [_n('MaterialApp')]);
      expect(isDegenerateTree(root), isTrue);
    });

    test('false when any descendant is local-project', () {
      final root = _n('RootWidget', children: [
        _n('MaterialApp', children: [_n('MyForm', local: true)]),
      ]);
      expect(isDegenerateTree(root), isFalse);
    });

    test('a local root alone does not count (root is skipped)', () {
      final root = _n('RootWidget', local: true, children: [_n('Framework')]);
      expect(isDegenerateTree(root), isTrue);
    });
  });
}
