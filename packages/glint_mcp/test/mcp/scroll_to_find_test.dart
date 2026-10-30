import 'package:dart_mcp/server.dart';
import 'package:glint_mcp/glint.dart';
import 'package:test/test.dart';

ResolvedCoord _coord({
  double y = 400,
  double opacity = 1,
  bool hittable = true,
  bool hitTestReal = true,
  String? hitBy,
}) =>
    ResolvedCoord(
      glintId: 'text#took',
      logicalCenter: (x: 200, y: y),
      logicalBounds: (x: 0, y: 0, w: 120, h: 20),
      devicePixelRatio: 3,
      logicalViewSize: (w: 420, h: 912),
      nearestAncestorOpacity: opacity,
      nearestAncestorVisible: true,
      hittable: hittable,
      hitTestReal: hitTestReal,
      hitBy: hitBy,
    );

/// A session whose screen always shows the same scene and resolves every node to [coord].
class _Session extends GlintSession {
  _Session(this.coord);
  final ResolvedCoord coord;

  @override
  SceneReader get reader => _Reader();

  @override
  CoordinateResolver get resolver => _Resolver(coord);
}

class _Reader implements SceneReader {
  @override
  Future<Scene> readSummary() async => Scene.forTesting(
        root: SceneNode(
          depth: 0,
          indexInParent: 0,
          description: 'Column',
          type: '_Element',
          inspectorId: 'i-column',
          glintId: 'column',
          children: [
            SceneNode(
              depth: 1,
              indexInParent: 0,
              description: 'Text',
              type: '_Element',
              inspectorId: 'i-took',
              glintId: 'text#took',
              textPreview: 'It took 22 years to build',
            ),
          ],
        ),
      );

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _Resolver implements CoordinateResolver {
  _Resolver(this.coord);
  final ResolvedCoord coord;

  @override
  Future<ResolvedCoord> resolve(Scene scene, String glintId) async => coord;

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

Future<StructuredResponse> _find(ResolvedCoord coord, Map<String, Object?> args) =>
    const ScrollToFindTool().handle(_Session(coord), CallToolRequest(name: 'scroll_to_find', arguments: args));

void main() {
  group('findVerdict', () {
    test('a lookup only needs the text painted on screen, not hittable', () {
      final covered = _coord(hittable: false, hitBy: 'container');
      expect(findVerdict(covered, tap: false), FindVerdict.found);
      expect(findVerdict(covered, tap: true), FindVerdict.covered);
    });

    test('a tap still needs the target hittable on screen', () {
      expect(findVerdict(_coord(), tap: true), FindVerdict.found);
      expect(findVerdict(_coord(y: 1400), tap: true), FindVerdict.keepScrolling);
    });

    test('an unpainted target is not found by a lookup and not called covered', () {
      final faded = _coord(opacity: 0, hittable: false);
      expect(findVerdict(faded, tap: false), FindVerdict.keepScrolling);
      expect(findVerdict(faded, tap: true), FindVerdict.keepScrolling);
    });

    test('off screen keeps scrolling either way', () {
      expect(findVerdict(_coord(y: -40), tap: false), FindVerdict.keepScrolling);
    });
  });

  group('scroll_to_find', () {
    test('finds plain text that a tap would not reach, and says what covers it', () async {
      final r = await _find(_coord(hittable: false, hitBy: 'container'), {'text': 'took', 'maxScrolls': 6});
      expect(r.isError, isFalse);
      expect(r.data?['glintId'], 'text#took');
      expect(r.data?['attempts'], 0);
      expect(r.data?['hittable'], isFalse);
      expect(r.warnings.join(), contains('container'));
    });

    test('tap:true on a covered target fails as notHittable, naming the cover', () async {
      final r =
          await _find(_coord(hittable: false, hitBy: 'container'), {'text': 'took', 'maxScrolls': 0, 'tap': true});
      expect(r.isError, isTrue);
      expect(r.data?['errorKind'], 'notHittable');
      expect(r.data?['coveredBy'], 'container');
      expect(r.summary, contains('covered'));
      expect(r.nextSteps.join(), contains('without tap:true'));
    });
  });
}
