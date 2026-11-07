import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_mcp/server.dart';

import 'process_tree.dart';

/// The call is being abandoned (its ceiling passed), so new subprocesses must not start.
class CallAbandoned implements Exception {
  const CallAbandoned(this.tool);
  final String tool;
  @override
  String toString() => 'CallAbandoned($tool): the call hit its time ceiling and was cancelled';
}

/// What one tool call is doing right now: feeds the heartbeat, names the stuck phase on a timeout, and owns the subprocesses to kill when the call is abandoned. Found from any code on the call via [current].
class CallProgress {
  CallProgress({required this.tool, this.token, this.send});

  final String tool;
  final ProgressToken? token;
  final void Function(ProgressNotification)? send;

  /// Awake time since the call began; stops while the Mac sleeps, unlike the wall clock.
  final Stopwatch clock = Stopwatch()..start();

  static const _zoneKey = #glintCallProgress;
  static const _trailMax = 8;

  String _phase = 'starting';
  int _phaseAtMs = 0;
  final List<({String phase, int ms})> _trail = [];
  final Map<Process, String> _processes = {};
  bool _abandoned = false;
  num _lastProgress = 0;
  int _lastSentAtMs = 0;
  final List<({DateTime at, int ms})> _sleeps = [];
  Timer? _heartbeat;
  Timer? _ceilingTimer;
  DateTime _lastWall = DateTime.now();
  int _lastAwakeMs = 0;

  /// The call running in the current zone, or null outside a tool call.
  static CallProgress? get current => Zone.current[_zoneKey] as CallProgress?;

  /// Marks the current phase of the running call; no-op outside a tool call, throws [CallAbandoned] once the call was cancelled.
  static void enter(String phase) {
    checkAlive();
    current?._set(phase);
  }

  /// Runs [body] under phase [phase], restoring the previous phase after.
  static Future<T> during<T>(String phase, Future<T> Function() body) async {
    final call = current;
    if (call == null) return body();
    checkAlive();
    final before = call._phase;
    call._set(phase);
    try {
      return await body();
    } finally {
      if (!call._abandoned) call._set(before);
    }
  }

  /// Throws [CallAbandoned] when the running call was cancelled.
  static void checkAlive() {
    final call = current;
    if (call != null && call._abandoned) throw CallAbandoned(call.tool);
  }

  String get phase => _phase;
  int get phaseMs => clock.elapsedMilliseconds - _phaseAtMs;
  bool get abandoned => _abandoned;

  /// The last phases with how long each ran, oldest first, ending with the current one.
  List<String> get trail => [
        for (final t in _trail) '${t.phase} (${_seconds(t.ms)})',
        '$_phase (${_seconds(phaseMs)}, still running)',
      ];

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  void _set(String phase) {
    if (phase == _phase) return;
    final now = clock.elapsedMilliseconds;
    _trail.add((phase: _phase, ms: now - _phaseAtMs));
    if (_trail.length > _trailMax) _trail.removeAt(0);
    _phase = phase;
    _phaseAtMs = now;
  }

  /// Runs [body] with this call as the current one for everything it starts.
  T run<T>(T Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  void registerProcess(Process process, String label) => _processes[process] = label;
  void unregisterProcess(Process process) => _processes.remove(process);

  /// Hands [process] over to outlive the running call, so abandoning the call leaves it running.
  static void release(Process process) => current?.unregisterProcess(process);

  /// Labels of the subprocesses this call still has running.
  List<String> get runningProcesses => _processes.values.toList();

  /// Wall-clock milliseconds the machine slept since [since], found by the one-second tick.
  int sleptSince(DateTime since) => _sleeps.where((s) => !s.at.isBefore(since)).fold(0, (a, s) => a + s.ms);

  /// Starts the one-second tick (sleep detection), the heartbeat every [heartbeatEvery], and the ceiling timer.
  void watch({
    required Duration ceiling,
    required void Function() onCeiling,
    Duration heartbeatEvery = const Duration(seconds: 10),
  }) {
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      _noteSleep();
      if (clock.elapsedMilliseconds - _lastSentAtMs >= heartbeatEvery.inMilliseconds - 500) _beat();
    });
    void arm(Duration wait) {
      _ceilingTimer = Timer(wait, () {
        final left = ceiling - clock.elapsed;
        if (left > const Duration(milliseconds: 250)) return arm(left);
        onCeiling();
      });
    }

    arm(ceiling);
  }

  void stop() {
    _heartbeat?.cancel();
    _ceilingTimer?.cancel();
  }

  void _noteSleep() {
    final wall = DateTime.now();
    final awake = clock.elapsedMilliseconds;
    final jump = wall.difference(_lastWall).inMilliseconds - (awake - _lastAwakeMs);
    if (jump > 3000) _sleeps.add((at: wall, ms: jump));
    _lastWall = wall;
    _lastAwakeMs = awake;
  }

  void _beat() {
    final tok = token;
    if (tok == null) return;
    final sec = (clock.elapsedMilliseconds / 1000).round();
    forward(ProgressNotification(progressToken: tok, progress: sec, message: '$tool: $_phase (${sec}s)'));
  }

  /// Sends [n] to the client with a progress value that only grows; a no-op without a client token or sender.
  void forward(ProgressNotification n) {
    final raw = send;
    final tok = token;
    if (raw == null || tok == null) return;
    _lastProgress = math.max(n.progress, _lastProgress + 1);
    _lastSentAtMs = clock.elapsedMilliseconds;
    try {
      raw(ProgressNotification(progressToken: tok, progress: _lastProgress, total: n.total, message: n.message));
    } on Object {
      return;
    }
  }

  /// Cancels the call's work: stops every subprocess it started, with its children, and refuses new phases and processes.
  void abandon() {
    _abandoned = true;
    stop();
    for (final p in _processes.keys.toList()) {
      unawaited(killProcessTree(p));
    }
    _processes.clear();
  }
}
