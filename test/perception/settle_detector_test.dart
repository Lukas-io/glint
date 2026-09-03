import 'package:glint/perception.dart';
import 'package:glint/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';

/// Scripted scheduler phases: each `evaluateString` pops the next phase, the
/// last one repeats forever.
class _FakeRuntime implements FlutterRuntime {
  _FakeRuntime(this.phases);
  final List<String> phases;
  int calls = 0;

  @override
  Future<String?> evaluateString(String expression) async {
    final i = calls < phases.length ? calls : phases.length - 1;
    calls++;
    return 'SchedulerPhase.${phases[i]}';
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// Scripted scenes: each `readSummary` yields the next root, the last repeats.
class _FakeReader extends SceneReader {
  _FakeReader(FlutterRuntime rt, this.roots)
      : super(InspectorClient(rt), rt);
  final List<SceneNode> roots;
  int reads = 0;

  @override
  Future<Scene> readSummary() async {
    final i = reads < roots.length ? reads : roots.length - 1;
    reads++;
    return Scene.forTesting(root: roots[i]);
  }
}

SceneNode _node(String label, {String? text, List<SceneNode> kids = const []}) =>
    SceneNode(
      depth: 1,
      indexInParent: 0,
      description: label,
      type: '_Element',
      inspectorId: 'i-$label',
      widgetRuntimeType: label,
      textPreview: text,
      glintId: label.toLowerCase(),
      children: kids,
    );

SettleDetector _detector(List<String> phases, List<SceneNode> roots) {
  final rt = _FakeRuntime(phases);
  return SettleDetector(
    runtime: rt,
    reader: _FakeReader(rt, roots),
    pollIntervalMs: 5,
    stabilityGapMs: 5,
  );
}

void main() {
  group('SettleDetector', () {
    test('idle frames with no loading affordance settle', () async {
      final d = _detector(['idle'], [_node('Scaffold')]);
      final r = await d.awaitSettle(ceilingMs: 500, quietFramesNeeded: 2);
      expect(r, isA<SettledOk>());
    });

    test('a RefreshIndicator wrapper is not a loading state', () async {
      final d = _detector(
        ['idle'],
        [_node('Scaffold', kids: [_node('RefreshIndicator')])],
      );
      final r = await d.awaitSettle(ceilingMs: 500, quietFramesNeeded: 2);
      expect(r, isA<SettledOk>());
    });

    test('a spinner keeps it loading until the ceiling', () async {
      final d = _detector(
        ['idle'],
        [_node('Scaffold', kids: [_node('CircularProgressIndicator')])],
      );
      final r = await d.awaitSettle(ceilingMs: 60, quietFramesNeeded: 1);
      expect(r, isA<SettledButLoading>());
      expect((r as SettledButLoading).loadingAffordances, isNotEmpty);
    });

    test('frames never quiet but content stable settles as animating',
        () async {
      final d = _detector(
        ['persistentCallbacks'],
        [_node('Scaffold', kids: [_node('Text', text: 'hello')])],
      );
      final r = await d.awaitSettle(
          ceilingMs: 400, quietFramesNeeded: 3, quietGraceMs: 20);
      expect(r, isA<SettledAnimating>());
      expect(r.settled, isTrue);
      expect(r.elapsedMs, lessThan(400));
    });

    test('frames never quiet and content changing times out', () async {
      var n = 0;
      final roots = List.generate(
          50, (_) => _node('Scaffold', kids: [_node('Text', text: '${n++}')]));
      final d = _detector(['persistentCallbacks'], roots);
      final r = await d.awaitSettle(
          ceilingMs: 80, quietFramesNeeded: 3, quietGraceMs: 10);
      expect(r, isA<SettleTimedOut>());
    });
  });

  test('contentSignature ignores offstage nodes and tracks text', () {
    final a = Scene.forTesting(
        root: _node('Scaffold', kids: [_node('Text', text: 'a')]));
    final b = Scene.forTesting(
        root: _node('Scaffold', kids: [_node('Text', text: 'b')]));
    final c = Scene.forTesting(
        root: _node('Scaffold', kids: [_node('Text', text: 'a')]));
    expect(a.contentSignature(), isNot(b.contentSignature()));
    expect(a.contentSignature(), c.contentSignature());
  });
}
