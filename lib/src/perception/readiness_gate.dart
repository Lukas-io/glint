import 'geometry.dart';
import 'scene_reader.dart';

/// §7.2 readiness primitive. Polls fresh scenes until [glintId] both
/// exists in the tree AND passes a hit test at its centre, OR the
/// ceiling is reached. The agent declares intent; this is the loop
/// the server runs while the agent does nothing.
class ReadinessGate {
  ReadinessGate({
    required this.reader,
    required this.resolver,
    this.pollIntervalMs = 100,
  });

  final SceneReader reader;
  final CoordinateResolver resolver;
  final int pollIntervalMs;

  Future<ReadinessResult> awaitReady({
    required String glintId,
    int ceilingMs = 5000,
  }) async {
    final start = DateTime.now();
    var attempts = 0;
    String? lastDetail;
    var sawInTree = false;

    while (true) {
      attempts++;
      final scene = await reader.readSummary();
      try {
        final node = scene.findByGlintId(glintId);
        if (node != null) {
          sawInTree = true;
          try {
            final coord = await resolver.resolve(scene, glintId);
            if (coord.hittable) {
              return ReadinessResult.ready(
                glintId: glintId,
                attempts: attempts,
                elapsedMs: DateTime.now().difference(start).inMilliseconds,
                coord: coord,
              );
            }
            lastDetail = 'painted=${coord.painted}, hittable=false, '
                'ancestorOpacity=${coord.nearestAncestorOpacity}';
          } on GeometryResolveError catch (e) {
            // Geometry can transiently fail mid-build; keep polling.
            lastDetail = 'geometry resolve error: ${e.message}';
          }
        } else {
          lastDetail = 'no node with glintId "$glintId" in scene';
        }
      } finally {
        await scene.dispose();
      }

      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (elapsed >= ceilingMs) {
        return sawInTree
            ? ReadinessResult.neverReady(
                glintId: glintId,
                attempts: attempts,
                elapsedMs: elapsed,
                detail: lastDetail,
              )
            : ReadinessResult.notFound(
                glintId: glintId,
                attempts: attempts,
                elapsedMs: elapsed,
              );
      }
      await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
    }
  }
}

/// Closed set of outcomes the gate can return.
sealed class ReadinessResult {
  const ReadinessResult({
    required this.glintId,
    required this.attempts,
    required this.elapsedMs,
  });

  factory ReadinessResult.ready({
    required String glintId,
    required int attempts,
    required int elapsedMs,
    required ResolvedCoord coord,
  }) = ReadyResult;

  factory ReadinessResult.neverReady({
    required String glintId,
    required int attempts,
    required int elapsedMs,
    String? detail,
  }) = NeverReadyResult;

  factory ReadinessResult.notFound({
    required String glintId,
    required int attempts,
    required int elapsedMs,
  }) = NotFoundResult;

  final String glintId;
  final int attempts;
  final int elapsedMs;
}

class ReadyResult extends ReadinessResult {
  const ReadyResult({
    required super.glintId,
    required super.attempts,
    required super.elapsedMs,
    required this.coord,
  });
  final ResolvedCoord coord;
}

class NeverReadyResult extends ReadinessResult {
  const NeverReadyResult({
    required super.glintId,
    required super.attempts,
    required super.elapsedMs,
    this.detail,
  });
  final String? detail;
}

class NotFoundResult extends ReadinessResult {
  const NotFoundResult({
    required super.glintId,
    required super.attempts,
    required super.elapsedMs,
  });
}
