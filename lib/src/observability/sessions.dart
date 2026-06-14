import 'dart:math';

import 'action_log.dart';

/// One named slice of activity — opens at a point in the [ActionLog]'s
/// sequence, closes at a later point. Sessions don't own their entries;
/// they hold a sequence range that [ActionLog.query] can slice on.
class Session {
  Session({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.firstSeq,
  });

  final String id;
  final String name;
  final DateTime startedAt;
  final int firstSeq;
  DateTime? endedAt;
  int? lastSeq;
  final List<SessionNote> notes = [];

  bool get isActive => endedAt == null;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'startedAt': startedAt.toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
        'firstSeq': firstSeq,
        if (lastSeq != null) 'lastSeq': lastSeq,
        'isActive': isActive,
        if (notes.isNotEmpty)
          'notes': notes.map((n) => n.toJson()).toList(),
      };
}

class SessionNote {
  SessionNote({required this.timestamp, required this.text});
  final DateTime timestamp;
  final String text;

  Map<String, Object?> toJson() => {
        'ts': timestamp.toIso8601String(),
        'text': text,
      };
}

/// Tracks one active session at a time plus the history of closed ones.
/// Opening a new session auto-closes the previous one.
class SessionManager {
  SessionManager({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<Session> _sessions = [];
  Session? _active;

  Session? get active => _active;
  List<Session> get history => List.unmodifiable(_sessions);

  Session open(String name, int currentSeq) {
    if (_active != null) _closeActive(currentSeq);
    final s = Session(
      id: _newId(),
      name: name,
      startedAt: _clock(),
      firstSeq: currentSeq,
    );
    _sessions.add(s);
    _active = s;
    return s;
  }

  Session? close(int currentSeq) {
    if (_active == null) return null;
    return _closeActive(currentSeq);
  }

  Session _closeActive(int currentSeq) {
    final s = _active!;
    s.endedAt = _clock();
    s.lastSeq = currentSeq - 1;
    _active = null;
    return s;
  }

  bool note(String text) {
    final s = _active;
    if (s == null) return false;
    s.notes.add(SessionNote(timestamp: _clock(), text: text));
    return true;
  }

  Session? byId(String id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  String _newId() {
    // Short, sortable, human-friendly. Not cryptographically anything —
    // session ids live within one process.
    final ts = _clock().millisecondsSinceEpoch.toRadixString(36);
    final rand = Random().nextInt(46656).toRadixString(36).padLeft(3, '0');
    return 's_${ts}_$rand';
  }
}
