import '../runtime/flutter_runtime.dart';
import 'scene_reader.dart';

/// §8.4 settle detection. Polls the scheduler phase; once [quietFramesNeeded]
/// quiet polls land it checks for loading affordances (a spinner is "frame-
/// stable" while loading) and keeps waiting up to the ceiling if any remain.
class SettleDetector {
  SettleDetector({
    required this.runtime,
    required this.reader,
    this.pollIntervalMs = 100,
  });

  final FlutterRuntime runtime;
  final SceneReader reader;
  final int pollIntervalMs;

  static const _loadingLabels = {
    'CircularProgressIndicator',
    'LinearProgressIndicator',
    'RefreshIndicator',
    'CupertinoActivityIndicator',
  };

  Future<SettleResult> awaitSettle({
    int ceilingMs = 5000,
    int quietFramesNeeded = 3,
    bool checkLoadingAffordances = true,
  }) async {
    final start = DateTime.now();
    var consecutiveQuiet = 0;

    while (true) {
      final idle = await _isIdle();
      if (idle) {
        consecutiveQuiet++;
      } else {
        consecutiveQuiet = 0;
      }

      final elapsed = DateTime.now().difference(start).inMilliseconds;

      if (consecutiveQuiet >= quietFramesNeeded) {
        if (!checkLoadingAffordances) {
          return SettleResult.settled(elapsedMs: elapsed);
        }
        final affordances = await _findLoadingAffordances();
        if (affordances.isEmpty) {
          return SettleResult.settled(elapsedMs: elapsed);
        }
        if (elapsed >= ceilingMs) {
          return SettleResult.loadingStable(
            elapsedMs: elapsed,
            loadingAffordances: affordances,
          );
        }
        // Spinner is steady; reset the quiet counter and keep waiting.
        consecutiveQuiet = 0;
      }

      if (elapsed >= ceilingMs) {
        return SettleResult.timedOut(elapsedMs: elapsed);
      }
      await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
    }
  }

  /// `schedulerPhase==idle` means no frame is mid-flight. We avoid
  /// `hasScheduledFrame`: VM-connected debug apps keep a frame perpetually
  /// scheduled (hot reload / devtools), so that flag never goes false.
  Future<bool> _isIdle() async {
    final s = await runtime
        .evaluateString('WidgetsBinding.instance.schedulerPhase.toString()');
    return s == 'SchedulerPhase.idle';
  }

  Future<List<String>> _findLoadingAffordances() async {
    final scene = await reader.readSummary();
    try {
      final hits = <String>[];
      for (final n in scene.root.walk()) {
        if (_loadingLabels.contains(n.label)) {
          hits.add(n.glintId ?? n.label);
        }
      }
      return hits;
    } finally {
      await scene.dispose();
    }
  }
}

sealed class SettleResult {
  const SettleResult({required this.elapsedMs});

  factory SettleResult.settled({required int elapsedMs}) = SettledOk;
  factory SettleResult.loadingStable({
    required int elapsedMs,
    required List<String> loadingAffordances,
  }) = SettledButLoading;
  factory SettleResult.timedOut({required int elapsedMs}) = SettleTimedOut;

  final int elapsedMs;
  bool get settled => this is SettledOk;
}

class SettledOk extends SettleResult {
  const SettledOk({required super.elapsedMs});
}

class SettledButLoading extends SettleResult {
  const SettledButLoading({
    required super.elapsedMs,
    required this.loadingAffordances,
  });
  final List<String> loadingAffordances;
}

class SettleTimedOut extends SettleResult {
  const SettleTimedOut({required super.elapsedMs});
}
