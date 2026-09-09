import 'package:glint/glint.dart';
import 'package:test/test.dart';

ResolvedCoord _coord({
  required double x,
  required double y,
  double vw = 420,
  double vh = 912,
  bool hittable = true,
}) {
  return ResolvedCoord(
    glintId: 'target',
    logicalCenter: (x: x, y: y),
    logicalBounds: (x: 0, y: 0, w: 40, h: 40),
    devicePixelRatio: 3,
    logicalViewSize: (w: vw, h: vh),
    nearestAncestorOpacity: 1,
    nearestAncestorVisible: true,
    hittable: hittable,
  );
}

void main() {
  group('key actions', () {
    test('PressKey dispatches key, count and modifiers', () async {
      final b = _FakeBackend();
      final ix = Interactor(backend: b, resolver: _FakeResolver(_coord(x: 10, y: 10)));
      final r = await ix.run(_FakeScene(),
          const PressKey(KeyName.left, count: 3, modifiers: {KeyModifier.shift}));
      expect(r.ok, isTrue);
      expect(b.keys.single.$1, KeyName.left);
      expect(b.keys.single.$2, 3);
      expect(b.keys.single.$3, {KeyModifier.shift});
    });

    test('ClearField selects all then backspaces once', () async {
      final b = _FakeBackend();
      final ix = Interactor(backend: b, resolver: _FakeResolver(_coord(x: 10, y: 10)));
      final r = await ix.run(_FakeScene(), const ClearField());
      expect(r.ok, isTrue);
      expect(b.selectAllCalls, 1);
      expect(b.keys.single.$1, KeyName.backspace);
    });
  });

  group('Interactor off-viewport gate', () {
    late _FakeBackend backend;

    Interactor build(ResolvedCoord coord) {
      backend = _FakeBackend();
      return Interactor(backend: backend, resolver: _FakeResolver(coord));
    }

    test('tap on on-screen target fires', () async {
      final i = build(_coord(x: 210, y: 456));
      final r = await i.run(_FakeScene(), const Tap(SymbolicTarget('target')));
      expect(r.ok, isTrue);
      expect(backend.taps, hasLength(1));
    });

    test('tap on target above the viewport refuses with offViewport', () async {
      final i = build(_coord(x: 210, y: -504));
      final r = await i.run(_FakeScene(), const Tap(SymbolicTarget('target')));
      expect(r.ok, isFalse);
      expect(r.errorKind, GlintErrorKind.offViewport);
      expect(r.nextSteps.join(), contains('scroll_to_find'));
      expect(backend.taps, isEmpty, reason: 'no gesture may fire off-screen');
    });

    test('tap on target below the viewport refuses', () async {
      final i = build(_coord(x: 210, y: 1400));
      final r = await i.run(_FakeScene(), const Tap(SymbolicTarget('target')));
      expect(r.errorKind, GlintErrorKind.offViewport);
    });

    test('long-press off-viewport refuses', () async {
      final i = build(_coord(x: -10, y: 100));
      final r =
          await i.run(_FakeScene(), const LongPress(SymbolicTarget('target')));
      expect(r.errorKind, GlintErrorKind.offViewport);
      expect(backend.longPresses, isEmpty);
    });

    test('swipe with off-screen from endpoint refuses', () async {
      final i = build(_coord(x: 210, y: -504));
      final r = await i.run(
        _FakeScene(),
        const Swipe(SymbolicTarget('target'), SymbolicTarget('target')),
      );
      expect(r.errorKind, GlintErrorKind.offViewport);
      expect(backend.swipes, isEmpty);
    });

    test('coordinate targets bypass the gate — caller owns raw coords', () async {
      final i = build(_coord(x: 0, y: 0));
      final r = await i.run(
        _FakeScene(),
        const Tap(CoordinateTarget(x: -50, y: -50)),
      );
      expect(r.ok, isTrue);
      expect(backend.taps, hasLength(1));
    });
  });
}

class _FakeBackend implements InteractionBackend {
  final taps = <(int, int)>[];
  final longPresses = <(int, int)>[];
  final swipes = <(int, int, int, int)>[];

  @override
  BackendCapabilities get capabilities => const BackendCapabilities();

  @override
  String get label => 'fake';

  @override
  Future<void> tap({required int physicalX, required int physicalY}) async {
    taps.add((physicalX, physicalY));
  }

  @override
  Future<void> longPress({
    required int physicalX,
    required int physicalY,
    required int durationMs,
  }) async {
    longPresses.add((physicalX, physicalY));
  }

  @override
  Future<void> swipe({
    required int physicalX1,
    required int physicalY1,
    required int physicalX2,
    required int physicalY2,
    required int durationMs,
  }) async {
    swipes.add((physicalX1, physicalY1, physicalX2, physicalY2));
  }

  final keys = <(KeyName, int, Set<KeyModifier>)>[];
  var selectAllCalls = 0;

  @override
  Future<void> typeText(String text) async {}

  @override
  Future<void> pressKey(KeyName key,
      {int count = 1, Set<KeyModifier> modifiers = const {}}) async {
    keys.add((key, count, modifiers));
  }

  @override
  Future<void> selectAll() async {
    selectAllCalls++;
  }

  @override
  Future<bool?> lockState() async => null;

  @override
  Future<void> pressHardwareButton(HardwareButton button) async {}

  @override
  Future<ScreenshotResult> screenshot(String path) async =>
      const ScreenshotResult();
}

class _FakeResolver implements CoordinateResolver {
  _FakeResolver(this.coord);
  final ResolvedCoord coord;

  @override
  Future<ResolvedCoord> resolve(Scene scene, String glintId) async => coord;

  @override
  Future<({double dpr, double w, double h})> resolveViewport(
          Scene scene, String glintId) async =>
      (dpr: 3.0, w: 420.0, h: 912.0);

  @override
  Future<({double dpr, double w, double h})> resolveViewportNodeFree() async =>
      (dpr: 3.0, w: 420.0, h: 912.0);
}

/// findByGlintId must return non-null so SymbolicTarget resolution proceeds.
class _FakeScene implements Scene {
  @override
  SceneNode? findByGlintId(String glintId) => SceneNode(
        depth: 1,
        indexInParent: 0,
        description: 'Fake',
        type: 't',
        inspectorId: 'inspector-1',
      );

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();

}
