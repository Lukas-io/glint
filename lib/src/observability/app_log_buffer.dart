import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

import '../runtime/flutter_runtime.dart';
import '../runtime/instance_text.dart';

/// Where a log entry came from. `stderr` captures direct stderr writes,
/// `stdout` captures FlutterError dumps + print() (Flutter routes
/// FlutterError through debugPrint → stdout, not stderr), `logging`
/// captures `developer.log` calls.
enum AppLogStream { stderr, stdout, logging }

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
  StreamSubscription<Event>? _stdoutSub;
  StreamSubscription<Event>? _logSub;
  VmService? _service;
  Future<void> _logQueue = Future.value();

  int get length => _entries.length;
  int get nextSequence => _seq;

  Future<void> subscribe(FlutterRuntime runtime) async {
    await unsubscribe();
    try {
      _service = runtime.rawService;
    } on Object {
      _service = null;
    }
    _stderrSub = runtime.stderrEvents.listen(_onStderr);
    _stdoutSub = runtime.stdoutEvents.listen(_onStdout);
    _logSub = runtime.loggingEvents.listen(_onLog);
  }

  Future<void> unsubscribe() async {
    final futures = [
      _stderrSub?.cancel(),
      _stdoutSub?.cancel(),
      _logSub?.cancel(),
    ];
    _stderrSub = null;
    _stdoutSub = null;
    _logSub = null;
    await Future.wait(futures.whereType<Future<void>>());
  }

  void _onStderr(Event event) {
    final bytes = event.bytes;
    if (bytes == null) return;
    final text = utf8.decode(base64Decode(bytes), allowMalformed: true);
    _append(stream: AppLogStream.stderr, content: text);
  }

  void _onStdout(Event event) {
    final bytes = event.bytes;
    if (bytes == null) return;
    final text = utf8.decode(base64Decode(bytes), allowMalformed: true);
    _append(stream: AppLogStream.stdout, content: text);
  }

  /// Queued so records keep their order while long values are fetched.
  void _onLog(Event event) {
    final rec = event.logRecord;
    if (rec == null) return;
    final receivedAt = DateTime.now();
    // Values are fetched as the record arrives; only the append waits its turn, and a failed record never blocks later ones.
    final values = _fetchValues(rec, event.isolate?.id);
    _logQueue = _logQueue
        .then((_) async => _appendLog(rec, await values, receivedAt))
        .catchError((Object _) {});
  }

  Future<List<String?>> _fetchValues(LogRecord rec, String? isolateId) {
    Future<String?> text(InstanceRef? ref) {
      final service = _service;
      if (service == null || isolateId == null) {
        return Future.value(ref?.kind == InstanceKind.kNull ? null : ref?.valueAsString);
      }
      return instanceText(service, isolateId, ref);
    }

    return Future.wait([
      text(rec.message),
      text(rec.error),
      text(rec.stackTrace),
      text(rec.loggerName),
    ]);
  }

  void _appendLog(LogRecord rec, List<String?> values, DateTime receivedAt) {
    final [msg, error, stack, logger] = values;
    _append(
      stream: AppLogStream.logging,
      content: [
        msg ?? '',
        if (error != null && error.isNotEmpty) 'error: $error',
        if (stack != null && stack.trim().isNotEmpty) stack.trimRight(),
      ].join('\n'),
      loggerName: logger,
      level: rec.level,
      timestamp: receivedAt,
    );
  }

  void _append({
    required AppLogStream stream,
    required String content,
    String? loggerName,
    int? level,
    DateTime? timestamp,
  }) {
    if (content.trim().isEmpty) return;
    _entries.add(AppLogEntry(
      sequence: _seq++,
      timestamp: timestamp ?? DateTime.now(),
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
