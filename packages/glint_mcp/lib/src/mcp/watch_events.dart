import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// The watch events of one glint process: an append-only JSON-lines file a shell monitor can tail, plus a recent-events ring for clients that poll.
class WatchEventLog {
  WatchEventLog({required this.dir, int? ownPid, this.maxFileBytes = 1 << 20, this.retained = 500})
      : ownPid = ownPid ?? pid;

  final String dir;
  final int ownPid;
  final int maxFileBytes;
  final int retained;

  final Queue<Map<String, Object?>> _ring = Queue();
  int _seq = 0;
  int _bytes = 0;
  bool _opened = false;

  /// Why the file cannot be written, when it cannot; events still reach [since].
  String? fileError;

  String get path => '$dir/$ownPid.jsonl';

  int get lastSeq => _seq;

  /// The oldest seq [since] can still return.
  int get oldestSeq => _ring.isEmpty ? _seq + 1 : _ring.first['seq']! as int;

  /// Creates the file so a monitor can follow it before the first event, and clears files of long-dead processes.
  void open() {
    if (_opened) return;
    _opened = true;
    try {
      Directory(dir).createSync(recursive: true);
      final file = File(path);
      if (!file.existsSync()) file.createSync();
      _bytes = file.lengthSync();
      _pruneStale();
    } on Object catch (e) {
      fileError = '$e';
    }
  }

  /// Stamps [fields] with the next seq and a UTC time, writes the line and returns the event.
  Map<String, Object?> append(Map<String, Object?> fields) {
    open();
    final event = <String, Object?>{'seq': ++_seq, 'ts': DateTime.now().toUtc().toIso8601String(), ...fields};
    _ring.add(event);
    while (_ring.length > retained) {
      _ring.removeFirst();
    }
    if (fileError == null) _write('${jsonEncode(event)}\n');
    return event;
  }

  /// Events after [sinceSeq], oldest first, for one watch when [watch] is set.
  List<Map<String, Object?>> since(int sinceSeq, {String? watch, int limit = 50}) => [
        for (final e in _ring)
          if ((e['seq']! as int) > sinceSeq && (watch == null || e['watch'] == watch)) e,
      ].take(limit).toList();

  /// Removes the file when nothing was ever written to it.
  void close() {
    if (!_opened || fileError != null) return;
    try {
      final file = File(path);
      if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
    } on Object {
      // a file left behind is pruned by the next glint
    }
  }

  void _write(String line) {
    try {
      if (_bytes + line.length > maxFileBytes) _rotate();
      File(path).writeAsStringSync(line, mode: FileMode.append);
      _bytes += line.length;
    } on Object catch (e) {
      fileError = '$e';
    }
  }

  void _rotate() {
    File(path).renameSync('$path.1');
    _bytes = 0;
  }

  void _pruneStale() {
    final cutoff = DateTime.now().subtract(const Duration(days: 2));
    final own = RegExp(r'^(\d+)\.jsonl(\.1)?$');
    for (final f in Directory(dir).listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final m = own.firstMatch(name);
      if (m == null || m.group(1) == '$ownPid') continue;
      try {
        if (f.lastModifiedSync().isBefore(cutoff)) f.deleteSync();
      } on Object {
        // another glint may be using it
      }
    }
  }
}
