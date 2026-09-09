import '../runtime/flutter_runtime.dart';
import 'scene_reader.dart';

/// Widget labels that mean "still loading" while they are in the tree.
/// `RefreshIndicator` is deliberately absent: it wraps a list permanently,
/// only `RefreshProgressIndicator` is mounted while a refresh is running.
const Set<String> kLoadingAffordanceLabels = {
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'RefreshProgressIndicator',
  'CupertinoActivityIndicator',
};

/// §8.4 settle detection. Polls the scheduler phase; once [quietFramesNeeded]
/// quiet polls land it checks for loading affordances (a spinner is "frame-
/// stable" while loading) and keeps waiting up to the ceiling if any remain.
/// A screen that never goes quiet (shimmer, Lottie, marquee) is settled once
/// two tree reads [stabilityGapMs] apart carry the same content signature.
class SettleDetector {
  SettleDetector({
    required this.runtime,
    required this.reader,
    this.pollIntervalMs = 100,
    this.stabilityGapMs = 250,
  });

  final FlutterRuntime runtime;
  final SceneReader reader;
  final int pollIntervalMs;
  final int stabilityGapMs;

  Future<SettleResult> awaitSettle({
    int ceilingMs = 5000,
    int quietFramesNeeded = 3,
    bool checkLoadingAffordances = true,
    int quietGraceMs = 1500,
  }) async {
    final start = DateTime.now();
    var consecutiveQuiet = 0;
    var stabilityChecked = false;
    final graceMs = quietGraceMs.clamp(0, ceilingMs);

    while (true) {
      final idle = await _isIdle();
      if (idle) {
        consecutiveQuiet++;
      } else {
        consecutiveQuiet = 0;
      }

      var elapsed = DateTime.now().difference(start).inMilliseconds;

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
        consecutiveQuiet = 0;
      } else if (!stabilityChecked && elapsed >= graceMs) {
        stabilityChecked = true;
        if (await _treeIsStable()) {
          elapsed = DateTime.now().difference(start).inMilliseconds;
          return SettleResult.animatingButStable(elapsedMs: elapsed);
        }
        elapsed = DateTime.now().difference(start).inMilliseconds;
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

  /// Two reads [stabilityGapMs] apart with the same content signature: the
  /// frames keep coming (an animation) but nothing the agent reads changes.
  Future<bool> _treeIsStable() async {
    try {
      final first = await _signature();
      await Future<void>.delayed(Duration(milliseconds: stabilityGapMs));
      final second = await _signature();
      return first == second;
    } on Object {
      return false;
    }
  }

  Future<String> _signature() async {
    final scene = await reader.readSummary();
    try {
      return scene.contentSignature();
    } finally {
      await scene.dispose();
    }
  }

  Future<List<String>> _findLoadingAffordances() async {
    final scene = await reader.readSummary();
    try {
      final hits = <String>[];
      for (final n in scene.root.walk()) {
        if (kLoadingAffordanceLabels.contains(n.label)) {
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
  factory SettleResult.animatingButStable({required int elapsedMs}) =
      SettledAnimating;
  factory SettleResult.loadingStable({
    required int elapsedMs,
    required List<String> loadingAffordances,
  }) = SettledButLoading;
  factory SettleResult.timedOut({required int elapsedMs}) = SettleTimedOut;

  final int elapsedMs;
  bool get settled => this is SettledOk || this is SettledAnimating;
}

class SettledOk extends SettleResult {
  const SettledOk({required super.elapsedMs});
}

/// Frames never went quiet but the readable content stopped changing.
class SettledAnimating extends SettleResult {
  const SettledAnimating({required super.elapsedMs});
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
