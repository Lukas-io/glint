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

/// Thrown by [CallProgress.timeboxed] when its body outlived its limit; says where the body had got to.
class CallTimeboxExceeded implements Exception {
  const CallTimeboxExceeded(this.limit,
      {this.elapsedMs = 0, this.phase = 'starting', this.trail = const [], this.unwound = true});
  final Duration limit;

  /// Whether the cancelled body had stopped by the time this was thrown; false when it was still inside a call that cannot be cut short.
  final bool unwound;
  final int elapsedMs;
  final String phase;
  final List<String> trail;
  @override
  String toString() => 'CallTimeboxExceeded(${limit.inMilliseconds} ms)';
}

class _Timebox {
  bool expired = false;
  final Stopwatch clock = Stopwatch()..start();
  final Map<Process, String> processes = {};
  final List<({String phase, int ms})> trail = [];
  String phase = 'starting';
  int phaseAtMs = 0;

  void phaseChanged(String next) {
    final now = clock.elapsedMilliseconds;
    trail.add((phase: phase, ms: now - phaseAtMs));
    if (trail.length > 8) trail.removeAt(0);
    phase = next;
    phaseAtMs = now;
  }

  List<String> get trailText => [
        for (final t in trail) '${t.phase} (${(t.ms / 1000).toStringAsFixed(1)}s)',
        '$phase (${((clock.elapsedMilliseconds - phaseAtMs) / 1000).toStringAsFixed(1)}s, still running)',
      ];
}

/// Where a call's counters stood at one moment; the difference between two marks is what happened in between.
class CallMark {
  const CallMark({this.atMs = 0, this.phases = const {}, this.vmTimeouts = 0, this.vmRetries = 0});

  final int atMs;
  final Map<String, int> phases;
  final int vmTimeouts;
  final int vmRetries;
}

/// What one tool call is doing right now: feeds the heartbeat, names the stuck phase on a timeout, and owns the subprocesses to kill when the call is abandoned. Found from any code on the call via [current].
class CallProgress {
  CallProgress({required this.tool, this.token, this.send}) {
    _inFlight++;
  }

  final String tool;
  final ProgressToken? token;
  final void Function(ProgressNotification)? send;

  /// Awake time since the call began; stops while the Mac sleeps, unlike the wall clock.
  final Stopwatch clock = Stopwatch()..start();

  static const _zoneKey = #glintCallProgress;
  static const _boxKey = #glintCallTimebox;
  static const _trailMax = 8;

  static int _inFlight = 0;

  String _phase = 'starting';
  String? _note;
  String? _label;
  String _baseKey = 'start';
  int _baseAtMs = 0;
  final Map<String, int> _phaseMs = {};
  final Map<String, int> _openSince = {};
  int _vmTimeouts = 0;
  int _vmRetries = 0;
  bool _counted = true;

  /// Set by a batch on the call that runs its steps, so every step's usage event names the batch.
  String? batchId;
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

  /// Marks the current phase of the running call, counted in usage events under [key]; no-op outside a tool call, throws [CallAbandoned] once the call was cancelled.
  static void enter(String phase, {required String key}) {
    checkAlive();
    final call = current;
    if (call == null) return;
    call._set(phase);
    call._startBase(key);
  }

  /// Runs [body] under phase [phase], restoring the previous phase after; its time counts under [key] and still counts in the phase it ran inside.
  static Future<T> during<T>(String phase, Future<T> Function() body, {required String key}) async {
    final call = current;
    if (call == null) return body();
    checkAlive();
    final before = call._phase;
    final owner = key != call._baseKey && !call._openSince.containsKey(key);
    if (owner) call._openSince[key] = call.clock.elapsedMilliseconds;
    call._set(phase);
    try {
      return await body();
    } finally {
      if (owner) call._closeNested(key);
      if (!call._abandoned) call._set(before);
    }
  }

  /// Tool calls running in this process right now.
  static int get inFlight => _inFlight;

  /// Counts a VM service call that hit its timeout, on the running call.
  static void noteVmTimeout() => current?._vmTimeouts++;

  /// Counts a VM service call that was repeated after the isolate changed, on the running call.
  static void noteVmRetry() => current?._vmRetries++;

  /// The counters and per-key milliseconds so far, including phases still running; a nested key's time is also in the phase around it.
  CallMark mark() {
    final now = clock.elapsedMilliseconds;
    final phases = Map<String, int>.of(_phaseMs);
    phases.update(_baseKey, (v) => v + now - _baseAtMs, ifAbsent: () => now - _baseAtMs);
    for (final e in _openSince.entries) {
      phases.update(e.key, (v) => v + now - e.value, ifAbsent: () => now - e.value);
    }
    return CallMark(atMs: now, phases: phases, vmTimeouts: _vmTimeouts, vmRetries: _vmRetries);
  }

  /// Throws [CallAbandoned] when the running call, or the [timeboxed] part it is in, was cancelled.
  static void checkAlive() {
    if (cancelled) throw CallAbandoned(current?.tool ?? 'step');
  }

  /// Whether the running call, or the [timeboxed] part it is in, was cancelled.
  static bool get cancelled =>
      (current?._abandoned ?? false) || ((Zone.current[_boxKey] as _Timebox?)?.expired ?? false);

  /// Sets what the heartbeat adds after the phase, such as what a wait last saw; null clears it. No-op outside a tool call.
  static void note(String? text) => current?._note = text;

  /// Sets which step of a longer call this is, shown after the phase in the heartbeat; null clears it.
  static void stepLabel(String? text) => current?._label = text;

  /// Runs [body] for at most [limit]. Past it the part is cancelled: its next [checkAlive] throws, the subprocesses it started are stopped, and after at most [unwind] for the body to finish this throws [CallTimeboxExceeded].
  static Future<T> timeboxed<T>(Duration limit, Future<T> Function() body,
      {Duration unwind = const Duration(seconds: 1)}) {
    final box = _Timebox();
    final done = Completer<T>();
    final finished = Completer<void>();
    final timer = Timer(limit, () async {
      box.expired = true;
      for (final p in box.processes.keys.toList()) {
        unawaited(killProcessTree(p));
      }
      box.processes.clear();
      await finished.future.timeout(unwind, onTimeout: () {});
      if (!done.isCompleted) {
        done.completeError(CallTimeboxExceeded(limit,
            elapsedMs: box.clock.elapsedMilliseconds,
            phase: box.phase,
            trail: box.trailText,
            unwound: finished.isCompleted));
      }
    });
    runZoned(() async {
      try {
        final value = await body();
        if (!done.isCompleted) done.complete(value);
      } on Object catch (e, st) {
        if (!done.isCompleted && !(box.expired && e is CallAbandoned)) done.completeError(e, st);
      } finally {
        if (!finished.isCompleted) finished.complete();
      }
    }, zoneValues: {_boxKey: box});
    return done.future.whenComplete(timer.cancel);
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
    (Zone.current[_boxKey] as _Timebox?)?.phaseChanged(phase);
    final now = clock.elapsedMilliseconds;
    _trail.add((phase: _phase, ms: now - _phaseAtMs));
    if (_trail.length > _trailMax) _trail.removeAt(0);
    _phase = phase;
    _phaseAtMs = now;
  }

  void _startBase(String key) {
    if (key == _baseKey) return;
    final now = clock.elapsedMilliseconds;
    _phaseMs.update(_baseKey, (v) => v + now - _baseAtMs, ifAbsent: () => now - _baseAtMs);
    _baseKey = key;
    _baseAtMs = now;
  }

  void _closeNested(String key) {
    final since = _openSince.remove(key);
    if (since == null) return;
    final spent = clock.elapsedMilliseconds - since;
    _phaseMs.update(key, (v) => v + spent, ifAbsent: () => spent);
  }

  /// Runs [body] with this call as the current one for everything it starts.
  T run<T>(T Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  void registerProcess(Process process, String label) {
    final box = Zone.current[_boxKey] as _Timebox?;
    (box?.processes ?? _processes)[process] = label;
  }

  void unregisterProcess(Process process) {
    _processes.remove(process);
    (Zone.current[_boxKey] as _Timebox?)?.processes.remove(process);
  }

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
    if (_counted) _inFlight--;
    _counted = false;
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
    final parts = [_phase, if (_label != null) _label, if (_note != null) _note];
    forward(ProgressNotification(progressToken: tok, progress: sec, message: '$tool: ${parts.join(' · ')} (${sec}s)'));
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
