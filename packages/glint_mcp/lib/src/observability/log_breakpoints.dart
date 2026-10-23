import 'dart:async';

import 'app_log_buffer.dart';

/// A regex armed on the app's log lines.
class LogBreakpoint {
  LogBreakpoint({
    required this.id,
    required this.pattern,
    this.stream,
    this.pause = true,
    this.once = false,
  });

  final String id;
  final RegExp pattern;
  final AppLogStream? stream;
  final bool pause;
  final bool once;
  int hits = 0;

  bool matches(AppLogEntry e) => (stream == null || e.stream == stream) && pattern.hasMatch(e.content);

  Map<String, Object?> toJson() => {
        'id': id,
        'pattern': pattern.pattern,
        if (stream != null) 'stream': stream!.name,
        'pause': pause,
        if (once) 'once': true,
        'hits': hits,
      };
}

/// One matched line: what matched, whether the app was paused for it, and the screen at that moment.
class BreakpointHit {
  BreakpointHit({required this.number, required this.breakpoint, required this.entry, required this.at});

  final int number;
  final LogBreakpoint breakpoint;
  final AppLogEntry entry;
  final DateTime at;
  bool paused = false;
  String? pauseError;
  String? screenshotPath;

  /// Lines that also matched while the app was already paused for this hit.
  final List<AppLogEntry> alsoMatched = [];

  String get matchedLine => entry.content.split('\n').first;

  Map<String, Object?> toJson() => {
        'hit': number,
        'breakpoint': breakpoint.id,
        'pattern': breakpoint.pattern.pattern,
        'line': matchedLine,
        'seq': entry.sequence,
        'stream': entry.stream.name,
        'at': at.toIso8601String(),
        'paused': paused,
        if (pauseError != null) 'pauseError': pauseError,
        if (screenshotPath != null) 'screenshot': screenshotPath,
        if (alsoMatched.isNotEmpty) 'alsoMatched': [for (final e in alsoMatched) e.content.split('\n').first],
      };
}

/// Log breakpoints for one app: matches each new log line, pauses the app on a hit, and queues hits for the agent.
class LogBreakpoints {
  LogBreakpoints({required this.pauseApp, required this.resumeApp, required this.capture});

  /// Pauses the app's isolates; returns an error message or null on success.
  final Future<String?> Function() pauseApp;

  /// Resumes the app's isolates; returns an error message or null on success.
  final Future<String?> Function() resumeApp;

  /// Screenshots the device; returns the PNG path or null.
  final Future<String?> Function() capture;

  final Map<String, LogBreakpoint> _armed = {};
  final List<BreakpointHit> _pending = [];
  final List<Completer<void>> _waiters = [];
  StreamSubscription<AppLogEntry>? _sub;
  BreakpointHit? _pausedFor;
  int _nextId = 1;
  int _hitCount = 0;

  List<LogBreakpoint> get armed => _armed.values.toList();
  List<BreakpointHit> get pending => List.unmodifiable(_pending);
  BreakpointHit? get pausedFor => _pausedFor;
  bool get isPaused => _pausedFor != null;

  /// Starts matching lines from [entries]; replaces any earlier source.
  void listen(Stream<AppLogEntry> entries) {
    _sub?.cancel();
    _sub = entries.listen(_onEntry);
  }

  LogBreakpoint add(RegExp pattern, {AppLogStream? stream, bool pause = true, bool once = false}) {
    final bp = LogBreakpoint(id: 'b${_nextId++}', pattern: pattern, stream: stream, pause: pause, once: once);
    _armed[bp.id] = bp;
    return bp;
  }

  /// Removes one breakpoint, or all when [id] is null; true when something was removed.
  bool remove(String? id) {
    if (id == null) {
      final had = _armed.isNotEmpty;
      _armed.clear();
      return had;
    }
    return _armed.remove(id) != null;
  }

  void _onEntry(AppLogEntry e) {
    final paused = _pausedFor;
    for (final bp in _armed.values.toList()) {
      if (!bp.matches(e)) continue;
      bp.hits++;
      if (bp.once) _armed.remove(bp.id);
      if (paused != null) {
        paused.alsoMatched.add(e);
        return;
      }
      final hit = BreakpointHit(number: ++_hitCount, breakpoint: bp, entry: e, at: DateTime.now());
      _pending.add(hit);
      if (bp.pause) {
        _pausedFor = hit;
        unawaited(_pauseFor(hit));
      } else {
        _wake();
      }
      return;
    }
  }

  Future<void> _pauseFor(BreakpointHit hit) async {
    final error = await pauseApp();
    hit.paused = error == null;
    hit.pauseError = error;
    if (error != null && identical(_pausedFor, hit)) _pausedFor = null;
    hit.screenshotPath = await capture();
    _wake();
  }

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  /// The oldest hit whose pause and screenshot are done, without consuming it.
  BreakpointHit? get ready {
    for (final h in _pending) {
      if (!h.breakpoint.pause || h.paused || h.pauseError != null) return h;
    }
    return null;
  }

  /// Waits up to [timeout] for a ready hit; null on timeout.
  Future<BreakpointHit?> next(Duration timeout) async {
    final now = ready;
    if (now != null) return now;
    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      _waiters.remove(waiter);
      return null;
    }
    return ready;
  }

  /// Resumes the app if paused and consumes the current hit; returns the resume error, if any.
  Future<({BreakpointHit? hit, String? error})> resume() async {
    final hit = _pausedFor ?? (_pending.isEmpty ? null : _pending.first);
    String? error;
    if (_pausedFor != null) {
      error = await resumeApp();
      if (error == null) _pausedFor = null;
    }
    if (error == null && hit != null) _pending.remove(hit);
    return (hit: hit, error: error);
  }

  /// Resumes a paused app and drops everything; used when glint lets go of the app.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (_pausedFor != null) await resumeApp();
    _pausedFor = null;
    _armed.clear();
    _pending.clear();
    _wake();
  }
}
