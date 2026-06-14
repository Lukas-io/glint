import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

import '../../perception.dart';

/// Where a log entry came from. `stderr` captures uncaught Flutter
/// exceptions (FlutterError dumps); `logging` captures `developer.log`
/// calls. `stdout` is intentionally not subscribed — too noisy in debug.
enum AppLogStream { stderr, logging }

class AppLogEntry {
  AppLogEntry({
    required this.sequence,
    required this.timestamp,
    required this.stream,
    required this.content,
    this.loggerName,
    this.level,
  });

  final int sequence;
  final DateTime timestamp;
  final AppLogStream stream;
  final String content;
  final String? loggerName;
  final int? level;

  bool get looksLikeError {
    final c = content.toLowerCase();
    return c.contains('exception') ||
        c.contains('error') ||
        c.contains('flutter error') ||
        c.contains('stack trace');
  }

  Map<String, Object?> toJson() => {
        'seq': sequence,
        'ts': timestamp.toIso8601String(),
        'stream': stream.name,
        if (loggerName != null) 'loggerName': loggerName,
        if (level != null) 'level': level,
        'content': content,
      };
}

/// Bounded ring of app-side log events. Subscribes to the VM service's
/// Stderr + Logging streams on [subscribe] and cancels them on
/// [unsubscribe]. Survives glint session re-attach: the buffer itself
/// outlives any one subscription.
class AppLogBuffer {
  AppLogBuffer({this.capacity = 500});

  final int capacity;
  final Queue<AppLogEntry> _entries = Queue();
  int _seq = 0;
  StreamSubscription<Event>? _stderrSub;
  StreamSubscription<Event>? _logSub;

  int get length => _entries.length;
  int get nextSequence => _seq;

  Future<void> subscribe(VmClient vm) async {
    await unsubscribe();
    final svc = vm.service;
    try {
      await svc.streamListen(EventStreams.kStderr);
    } on Object {
      // already listening — fine
    }
    try {
      await svc.streamListen(EventStreams.kLogging);
    } on Object {
      // already listening — fine
    }
    _stderrSub = svc.onStderrEvent.listen(_onStderr);
    _logSub = svc.onLoggingEvent.listen(_onLog);
  }

  Future<void> unsubscribe() async {
    final s = _stderrSub;
    final l = _logSub;
    _stderrSub = null;
    _logSub = null;
    await s?.cancel();
    await l?.cancel();
  }

  void _onStderr(Event event) {
    final bytes = event.bytes;
    if (bytes == null) return;
    final text = utf8.decode(base64Decode(bytes), allowMalformed: true);
    _append(stream: AppLogStream.stderr, content: text);
  }

  void _onLog(Event event) {
    final rec = event.logRecord;
    if (rec == null) return;
    final msg = rec.message?.valueAsString ?? '';
    final loggerName = rec.loggerName?.valueAsString;
    _append(
      stream: AppLogStream.logging,
      content: msg,
      loggerName: loggerName,
      level: rec.level,
    );
  }

  void _append({
    required AppLogStream stream,
    required String content,
    String? loggerName,
    int? level,
  }) {
    if (content.trim().isEmpty) return;
    _entries.add(AppLogEntry(
      sequence: _seq++,
      timestamp: DateTime.now(),
      stream: stream,
      content: content,
      loggerName: loggerName,
      level: level,
    ));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  Iterable<AppLogEntry> query({
    int? sinceSeq,
    AppLogStream? streamFilter,
    bool errorsOnly = false,
    int limit = 50,
  }) {
    Iterable<AppLogEntry> out = _entries;
    if (sinceSeq != null) out = out.where((e) => e.sequence >= sinceSeq);
    if (streamFilter != null) {
      out = out.where((e) => e.stream == streamFilter);
    }
    if (errorsOnly) out = out.where((e) => e.looksLikeError);
    return out.toList().reversed.take(limit).toList().reversed;
  }

  void clear() {
    _entries.clear();
    _seq = 0;
  }
}
