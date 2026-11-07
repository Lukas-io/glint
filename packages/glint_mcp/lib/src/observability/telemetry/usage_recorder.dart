/// Records tool-usage events for glint, mirroring flutter_network_mcp's
/// privacy-safe model: tool NAME, arg KEYS only (never values), outcome
/// category, errorKind, duration, result size. Events live in a bounded
/// in-memory ring AND, when a data dir is given, in an append-only JSONL
/// store so a later process can still ship them.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:glint_core/glint_core.dart';
import 'package:path/path.dart' as p;

import '../../version.dart';
import 'env.dart';

/// `ok` / `error` / `empty`. Same vocabulary as flutter_network_mcp.
enum ToolOutcome { ok, error, empty }

class ToolEvent {
  ToolEvent({
    required this.id,
    required this.tsMs,
    required this.correlationId,
    required this.tool,
    required this.outcome,
    required this.argKeys,
    required this.durationMs,
    required this.resultBytes,
    this.errorKind,
    this.diagnostics = const {},
  });

  final int id;
  final int tsMs;
  final String correlationId;
  final String tool;
  final ToolOutcome outcome;
  final List<String> argKeys;
  final int durationMs;
  final int resultBytes;
  final String? errorKind;

  /// Local-only fields for diagnosing a slow or failed call; never part of anything shipped.
  final Map<String, Object?> diagnostics;

  /// The columns every consumer of the rows knows; everything else in a stored row is [diagnostics].
  static const Set<String> baseKeys = {
    'id',
    'ts_ms',
    'correlation_id',
    'tool',
    'outcome',
    'arg_keys',
    'duration_ms',
    'result_bytes',
    'error_kind',
  };

  /// [row] without its [diagnostics].
  static Map<String, Object?> baseOnly(Map<String, Object?> row) => {
        for (final e in row.entries)
          if (baseKeys.contains(e.key)) e.key: e.value,
      };

  /// Row form consumed by [summarizeUsage], plus the [diagnostics].
  Map<String, Object?> toRow() => {
        'id': id,
        'ts_ms': tsMs,
        'correlation_id': correlationId,
        'tool': tool,
        'outcome': outcome.name,
        'arg_keys': argKeys.join(','),
        'duration_ms': durationMs,
        'result_bytes': resultBytes,
        if (errorKind != null) 'error_kind': errorKind,
        for (final e in diagnostics.entries)
          if (!baseKeys.contains(e.key)) e.key: e.value,
      };

  static ToolEvent? fromRow(Map<String, Object?> r) {
    final id = r['id'];
    final tool = r['tool'];
    if (id is! int || tool is! String) return null;
    final outcomeName = r['outcome'] as String?;
    final outcome = ToolOutcome.values.cast<ToolOutcome?>().firstWhere(
          (o) => o!.name == outcomeName,
          orElse: () => null,
        );
    final argKeysRaw = r['arg_keys'];
    return ToolEvent(
      id: id,
      tsMs: (r['ts_ms'] as int?) ?? 0,
      correlationId: (r['correlation_id'] as String?) ?? '',
      tool: tool,
      outcome: outcome ?? ToolOutcome.ok,
      argKeys: argKeysRaw is String && argKeysRaw.isNotEmpty ? argKeysRaw.split(',') : const [],
      durationMs: (r['duration_ms'] as int?) ?? 0,
      resultBytes: (r['result_bytes'] as int?) ?? 0,
      errorKind: r['error_kind'] as String?,
      diagnostics: {
        for (final e in r.entries)
          if (!baseKeys.contains(e.key)) e.key: e.value,
      },
    );
  }
}

/// Bounded ring of [ToolEvent]s with FNM-style correlation IDs, backed by
/// [UsageEventStore] when a data dir is configured. One process-wide
/// instance; tool handlers call [record] post-call.
class UsageRecorder implements UsageEventSource {
  UsageRecorder.config({
    required this.enabled,
    this.gapMs = 60000,
    this.capacity = 50000,
    String? dataDir,
  }) : store = (enabled && dataDir != null) ? UsageEventStore(dataDir) : null {
    _nextId = (store?.lastId ?? 0) + 1;
    _uptime.start();
  }

  /// Default constructor reads env: `GLINT_NO_TELEMETRY` /
  /// `GLINT_NO_USAGE` disable; `GLINT_USAGE_GAP_MS` overrides the gap.
  factory UsageRecorder.fromEnv() {
    final env = io.Platform.environment;
    final off = usageDisabled(env);
    final gapRaw = int.tryParse(env['GLINT_USAGE_GAP_MS'] ?? '');
    final gap = (gapRaw == null || gapRaw < 1000) ? 60000 : gapRaw;
    return UsageRecorder.config(
      enabled: !off,
      gapMs: gap,
      dataDir: off || underTestRunner() ? null : resolveDataDir(),
    );
  }

  /// True inside `dart test`: unit tests build real sessions, and their
  /// synthetic calls must never land in the user's usage store.
  static bool underTestRunner() => io.Platform.script.path.contains('dart_test');

  final bool enabled;
  final int gapMs;
  final int capacity;

  /// Null when persistence is off (disabled, or no data dir).
  final UsageEventStore? store;

  final Stopwatch _uptime = Stopwatch();
  final Queue<ToolEvent> _events = Queue();
  late int _nextId;
  late final TurnTracker _turns = TurnTracker(gapMs: gapMs);

  int get length => _events.length;
  int get nextId => _nextId;

  /// Highest id ever assigned in this store (0 when empty).
  int get maxId => _nextId - 1;

  bool get persists => store != null;

  /// Rolls over after the idle gap. Public so it's unit-testable.
  String correlationIdFor(int nowMs) => _turns.correlationIdFor(nowMs);

  void record({
    required String tool,
    required ToolOutcome outcome,
    required List<String> argKeys,
    required int durationMs,
    required int resultBytes,
    String? errorKind,
    Map<String, Object?> diagnostics = const {},
  }) {
    if (!enabled) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final event = ToolEvent(
      id: _nextId++,
      tsMs: nowMs,
      correlationId: correlationIdFor(nowMs),
      tool: tool,
      outcome: outcome,
      argKeys: argKeys,
      durationMs: durationMs,
      resultBytes: resultBytes,
      errorKind: errorKind,
      diagnostics: {
        'version': glintVersion,
        'pid': io.pid,
        'uptime_s': _uptime.elapsed.inSeconds,
        ...diagnostics,
      },
    );
    _events.add(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    store?.append(event);
  }

  /// Rows newer than [afterId], in insertion order. Reads the persisted store
  /// when there is one (so events from earlier processes are included).
  List<Map<String, Object?>> eventsAfterId(int afterId, {int limit = 50000}) {
    final s = store;
    if (s != null) return s.rowsAfterId(afterId, limit: limit);
    final out = <Map<String, Object?>>[];
    for (final e in _events) {
      if (e.id <= afterId) continue;
      out.add(e.toRow());
      if (out.length >= limit) break;
    }
    return out;
  }

  /// What the shipper reads: the base columns only, so the diagnostic fields never leave this machine.
  @override
  List<Map<String, Object?>> eventsAfter(int afterId, {required int limit}) =>
      [for (final row in eventsAfterId(afterId, limit: limit)) ToolEvent.baseOnly(row)];

  @override
  int get maxEventId => maxId;

  static List<String> argKeysFrom(Map<String, Object?>? args) => usageArgKeys(args);

  static ToolOutcome outcomeFrom({
    required bool isError,
    Map<String, Object?>? structured,
  }) =>
      ToolOutcome.values.byName(usageOutcome(isError: isError, structured: structured));

  void clearForTest() {
    _events.clear();
    _nextId = 1;
    _turns.reset();
  }
}

/// Append-only JSONL store at `<dataDir>/usage-events.jsonl`; ids stay monotonic across processes, and a full file is gzipped into `usage-archive/` (newest 20 MB kept) instead of being cut. Writes are best-effort and never throw.
class UsageEventStore {
  UsageEventStore(
    this.dataDir, {
    this.rotateBytes = 5 * 1024 * 1024,
    this.keepOnRotate = 5000,
    this.archiveMaxBytes = 20 * 1024 * 1024,
    this.retryAfter = const Duration(minutes: 5),
  }) {
    lastId = _readLastId();
  }

  static const String fileName = 'usage-events.jsonl';
  static const String archiveDirName = 'usage-archive';

  final String dataDir;
  final int rotateBytes;

  /// Newest lines that stay in the live file after a rotation, so reports keep their window and ids keep counting up.
  final int keepOnRotate;
  final int archiveMaxBytes;

  /// How long a rotation that found nothing to archive, or failed, waits before reading the file again.
  final Duration retryAfter;

  /// Highest id present in the file at open time, then after each append.
  late int lastId;

  DateTime? _retryAt;

  String get path => p.join(dataDir, fileName);

  String get archiveDir => p.join(dataDir, archiveDirName);

  void append(ToolEvent event) {
    try {
      final file = io.File(path);
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync('${jsonEncode(event.toRow())}\n', mode: io.FileMode.append, flush: true);
      lastId = event.id;
      _maybeRotate(file);
    } on Object {
      // Persistence is best-effort; the in-memory ring still has the event.
    }
  }

  /// Rows with id > [afterId], oldest first.
  List<Map<String, Object?>> rowsAfterId(int afterId, {int limit = 50000}) {
    final out = <Map<String, Object?>>[];
    for (final row in _rows()) {
      final id = row['id'];
      if (id is! int || id <= afterId) continue;
      out.add(row);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Total persisted rows (bounded by rotation).
  int count() => _rows().length;

  Iterable<Map<String, Object?>> _rows() sync* {
    final file = io.File(path);
    if (!file.existsSync()) return;
    List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } on Object {
      return;
    }
    for (final line in lines) {
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, Object?>) yield decoded;
      } on Object {
        // skip a torn line
      }
    }
  }

  int _readLastId() {
    var last = 0;
    for (final row in _rows()) {
      final id = row['id'];
      if (id is int && id > last) last = id;
    }
    return last;
  }

  void _maybeRotate(io.File file) {
    if (file.lengthSync() < rotateBytes) return;
    final now = DateTime.now();
    if (_retryAt case final at? when now.isBefore(at)) return;
    _retryAt = now.add(retryAfter);
    final lines = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
    if (lines.length <= keepOnRotate) return;
    final cut = lines.length - keepOnRotate;
    final archivable = _archivable(lines, cut, file.lengthSync());
    if (archivable == 0) return;
    final archived = _archive(lines.sublist(0, archivable));
    final drop = archived ? archivable : cut;
    file.writeAsStringSync('${lines.sublist(drop).join('\n')}\n', flush: true);
    if (archived) _trimArchive();
    if (file.lengthSync() < rotateBytes) _retryAt = null;
  }

  /// How many of the first [limit] [lines] may leave the live file: those the shipper has passed, all of them when sharing is off or the file passed four times its size.
  int _archivable(List<String> lines, int limit, int bytes) {
    final through = bytes >= rotateBytes * 4 ? null : _shippedThrough();
    if (through == null) return limit;
    var n = 0;
    while (n < limit && _idOf(lines[n]) <= through) {
      n++;
    }
    return n;
  }

  /// The highest id the shipper has sent, or null when nothing will be shipped (sharing is off).
  int? _shippedThrough() {
    if (sharingOffReason() != null) return null;
    try {
      final state = jsonDecode(io.File(p.join(dataDir, UsageShipper.stateFileName)).readAsStringSync());
      final mark = state is Map ? state['lastShippedEventId'] : null;
      return mark is int && mark <= lastId ? mark : 0;
    } on Object {
      return 0;
    }
  }

  /// Gzips [lines] into a new file in the archive dir, written aside and renamed; false when it could not be written.
  bool _archive(List<String> lines) {
    try {
      final dir = io.Directory(archiveDir)..createSync(recursive: true);
      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first;
      final random = Random.secure();
      final suffix = List.generate(3, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final name = 'usage-events-$stamp-$suffix-${_idOf(lines.first)}-${_idOf(lines.last)}.jsonl.gz';
      final target = io.File(p.join(dir.path, name));
      if (target.existsSync()) return false;
      final aside = io.File('${target.path}.tmp')
        ..writeAsBytesSync(io.gzip.encode(utf8.encode('${lines.join('\n')}\n')));
      aside.renameSync(target.path);
      return true;
    } on Object {
      return false;
    }
  }

  static int _idOf(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map && decoded['id'] is int ? decoded['id'] as int : 0;
    } on Object {
      return 0;
    }
  }

  /// Deletes the oldest archives (by modified time) until the dir holds at most [archiveMaxBytes], and leftover partial writes.
  void _trimArchive() {
    try {
      final all = io.Directory(archiveDir).listSync().whereType<io.File>().toList();
      final stale = DateTime.now().subtract(const Duration(minutes: 10));
      for (final f in all.where((f) => f.path.endsWith('.tmp') && f.lastModifiedSync().isBefore(stale))) {
        f.deleteSync();
      }
      final files = all.where((f) => f.path.endsWith('.gz')).toList()
        ..sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
      for (final f in files) {
        if (total <= archiveMaxBytes) break;
        total -= f.lengthSync();
        f.deleteSync();
      }
    } on Object {
      return;
    }
  }
}
