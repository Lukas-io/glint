import 'dart:collection';

import '../../interaction.dart';

/// Closed set of log entry kinds. Sealed so the `logs` tool can branch
/// exhaustively when rendering.
sealed class LogEntry {
  const LogEntry({
    required this.sequence,
    required this.timestamp,
    required this.tool,
    required this.elapsedMs,
  });

  final int sequence;
  final DateTime timestamp;
  final String tool;
  final int elapsedMs;

  Map<String, Object?> toJson();
}

class SuccessEntry extends LogEntry {
  const SuccessEntry({
    required super.sequence,
    required super.timestamp,
    required super.tool,
    required super.elapsedMs,
    required this.summary,
    this.args,
    this.armed,
  });

  final String summary;
  final Map<String, Object?>? args;
  final Map<String, Object?>? armed;

  @override
  Map<String, Object?> toJson() => {
        'seq': sequence,
        'kind': 'success',
        'ts': timestamp.toIso8601String(),
        'tool': tool,
        'elapsedMs': elapsedMs,
        'summary': summary,
        if (args != null) 'args': args,
        if (armed != null) 'armed': armed,
      };
}

class FailureEntry extends LogEntry {
  const FailureEntry({
    required super.sequence,
    required super.timestamp,
    required super.tool,
    required super.elapsedMs,
    required this.summary,
    required this.errorKind,
    this.detail,
    this.args,
  });

  final String summary;
  final GlintErrorKind errorKind;
  final String? detail;
  final Map<String, Object?>? args;

  @override
  Map<String, Object?> toJson() => {
        'seq': sequence,
        'kind': 'failure',
        'ts': timestamp.toIso8601String(),
        'tool': tool,
        'elapsedMs': elapsedMs,
        'summary': summary,
        'errorKind': errorKind.name,
        if (detail != null) 'detail': detail,
        if (args != null) 'args': args,
      };
}

/// Bounded ring of [LogEntry]s. Oldest entries drop off when the
/// capacity is reached. Thread of execution is single per session, so
/// no locking.
class ActionLog {
  ActionLog({this.capacity = 200}) : _entries = Queue<LogEntry>();

  final int capacity;
  final Queue<LogEntry> _entries;
  int _seq = 0;

  int get length => _entries.length;
  int get nextSequence => _seq;

  void record(LogEntry entry) {
    _entries.add(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  /// Returns the next sequence number for callers building entries.
  int allocateSequence() => _seq++;

  Iterable<LogEntry> query({
    int? sinceSeq,
    DateTime? sinceTs,
    String? toolFilter,
    bool? failuresOnly,
    int limit = 50,
  }) {
    Iterable<LogEntry> out = _entries;
    if (sinceSeq != null) out = out.where((e) => e.sequence >= sinceSeq);
    if (sinceTs != null) out = out.where((e) => !e.timestamp.isBefore(sinceTs));
    if (toolFilter != null) out = out.where((e) => e.tool == toolFilter);
    if (failuresOnly == true) out = out.whereType<FailureEntry>();
    return out.toList().reversed.take(limit).toList().reversed;
  }

  void clear() {
    _entries.clear();
    _seq = 0;
  }
}
