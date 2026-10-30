import '../runtime/flutter_runtime.dart' show RuntimeUnresponsiveError;
import 'geometry.dart';
import 'id_suggest.dart';
import 'inspector_client.dart' show appBusyCause;
import 'scene_reader.dart';

/// §7.2 readiness primitive. Polls fresh scenes until [glintId] both exists in
/// the tree AND passes a hit test at its centre, or the ceiling is reached.
class ReadinessGate {
  ReadinessGate({
    required this.reader,
    required this.resolver,
    this.pollIntervalMs = 100,
  });

  final SceneReader reader;
  final CoordinateResolver resolver;
  final int pollIntervalMs;

  /// Polls until [glintId] is hittable and not faded to opacity 0, or the ceiling. A screen whose
  /// content has not changed for [staleAfterMs] and still lacks the target
  /// fails fast as notFound (with id suggestions) — a static screen will not
  /// grow the node by waiting.
  Future<ReadinessResult> awaitReady({
    required String glintId,
    int ceilingMs = 5000,
    int staleAfterMs = 1500,
  }) async {
    final start = DateTime.now();
    var attempts = 0;
    String? lastDetail;
    var sawInTree = false;
    String? lastSignature;
    DateTime? stableSince;
    var suggestions = const <String>[];
    RuntimeUnresponsiveError? busy;

    while (true) {
      attempts++;
      busy = null;
      final Scene scene;
      try {
        scene = await reader.readSummary();
      } on Object catch (e) {
        busy = appBusyCause(e);
        if (busy == null) rethrow;
        if (DateTime.now().difference(start).inMilliseconds >= ceilingMs) {
          return ReadinessResult.busy(
              glintId: glintId,
              attempts: attempts,
              elapsedMs: DateTime.now().difference(start).inMilliseconds,
              timeout: busy.timeout);
        }
        await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
        continue;
      }
      try {
        final node = scene.findByGlintId(glintId);
        if (node == null) {
          final sig = scene.contentSignature();
          if (sig != lastSignature) {
            lastSignature = sig;
            stableSince = DateTime.now();
          }
          suggestions = suggestIds(
            [
              for (final n in scene.root.walk())
                if (n.glintId != null && !n.isOffstage) n.glintId!
            ],
            glintId,
          );
          final stableMs = DateTime.now().difference(stableSince!).inMilliseconds;
          if (!sawInTree && stableMs >= staleAfterMs) {
            return ReadinessResult.notFound(
              glintId: glintId,
              attempts: attempts,
              elapsedMs: DateTime.now().difference(start).inMilliseconds,
              suggestions: suggestions,
              staleScreen: true,
            );
          }
        }
        if (node != null) {
          sawInTree = true;
          try {
            final coord = await resolver.resolve(scene, glintId);
            if (coord.hittable && coord.nearestAncestorOpacity > 0) {
              return ReadinessResult.ready(
                glintId: glintId,
                attempts: attempts,
                elapsedMs: DateTime.now().difference(start).inMilliseconds,
                coord: coord,
              );
            }
            lastDetail = 'painted=${coord.painted}, hittable=${coord.hittable}, '
                'ancestorOpacity=${coord.nearestAncestorOpacity}';
          } on GeometryResolveError catch (e) {
            // Geometry can transiently fail mid-build; keep polling.
            lastDetail = 'geometry resolve error: ${e.message}';
          } on Object catch (e) {
            busy = appBusyCause(e);
            if (busy == null) rethrow;
            lastDetail = 'the app did not answer within ${busy.timeout.inSeconds}s';
          }
        } else {
          lastDetail = 'no node with glintId "$glintId" in scene';
        }
      } finally {
        await scene.dispose();
      }

      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (elapsed >= ceilingMs) {
        if (busy != null) {
          return ReadinessResult.busy(glintId: glintId, attempts: attempts, elapsedMs: elapsed, timeout: busy.timeout);
        }
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
                suggestions: suggestions,
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

  factory ReadinessResult.busy({
    required String glintId,
    required int attempts,
    required int elapsedMs,
    required Duration timeout,
  }) = BusyResult;

  factory ReadinessResult.notFound({
    required String glintId,
    required int attempts,
    required int elapsedMs,
    List<String> suggestions,
    bool staleScreen,
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

/// The app's VM stopped answering while the gate polled and had not recovered by the ceiling.
class BusyResult extends ReadinessResult {
  const BusyResult({
    required super.glintId,
    required super.attempts,
    required super.elapsedMs,
    required this.timeout,
  });
  final Duration timeout;
}

class NotFoundResult extends ReadinessResult {
  const NotFoundResult({
    required super.glintId,
    required super.attempts,
    required super.elapsedMs,
    this.suggestions = const [],
    this.staleScreen = false,
  });

  /// Closest ids on the last screen read.
  final List<String> suggestions;

  /// True when the gate gave up early because the screen stopped changing.
  final bool staleScreen;
}
