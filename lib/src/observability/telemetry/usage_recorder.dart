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

import 'package:path/path.dart' as p;

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

  /// Row form consumed by [summarizeUsage].
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
      argKeys: argKeysRaw is String && argKeysRaw.isNotEmpty
          ? argKeysRaw.split(',')
          : const [],
      durationMs: (r['duration_ms'] as int?) ?? 0,
      resultBytes: (r['result_bytes'] as int?) ?? 0,
      errorKind: r['error_kind'] as String?,
    );
  }
}

/// Bounded ring of [ToolEvent]s with FNM-style correlation IDs, backed by
/// [UsageEventStore] when a data dir is configured. One process-wide
/// instance; tool handlers call [record] post-call.
class UsageRecorder {
  UsageRecorder.config({
    required this.enabled,
    this.gapMs = 60000,
    this.capacity = 50000,
    String? dataDir,
  }) : store = (enabled && dataDir != null) ? UsageEventStore(dataDir) : null {
    _nextId = (store?.lastId ?? 0) + 1;
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
      dataDir: off ? null : resolveDataDir(),
    );
  }

  final bool enabled;
  final int gapMs;
  final int capacity;

  /// Null when persistence is off (disabled, or no data dir).
  final UsageEventStore? store;

  final Queue<ToolEvent> _events = Queue();
  late int _nextId;
  final String _procToken = _randomToken();
  int _turnSeq = 0;
  int _lastEventMs = 0;
  String _correlationId = '';

  int get length => _events.length;
  int get nextId => _nextId;

  /// Highest id ever assigned in this store (0 when empty).
  int get maxId => _nextId - 1;

  bool get persists => store != null;

  /// Rolls over after the idle gap. Public so it's unit-testable.
  String correlationIdFor(int nowMs) {
    if (_correlationId.isEmpty || nowMs - _lastEventMs > gapMs) {
      _turnSeq++;
      _correlationId = '$_procToken-$_turnSeq';
    }
    _lastEventMs = nowMs;
    return _correlationId;
  }

  void record({
    required String tool,
    required ToolOutcome outcome,
    required List<String> argKeys,
    required int durationMs,
    required int resultBytes,
    String? errorKind,
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

  /// Sorted arg keys — never values.
  static List<String> argKeysFrom(Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return const [];
    return args.keys.toList()..sort();
  }

  static ToolOutcome outcomeFrom({
    required bool isError,
    Map<String, Object?>? structured,
  }) {
    if (isError) return ToolOutcome.error;
    if (structured != null && structured['count'] == 0) {
      return ToolOutcome.empty;
    }
    return ToolOutcome.ok;
  }

  void clearForTest() {
    _events.clear();
    _nextId = 1;
    _correlationId = '';
    _turnSeq = 0;
    _lastEventMs = 0;
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(
      4,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

/// Append-only JSONL store at `<dataDir>/usage-events.jsonl`, one event per
/// line. Ids are monotonic across processes (the next id continues from the
/// last line). Rotates by keeping the newest [keepOnRotate] lines once the
/// file passes [rotateBytes]; every write is best-effort and never throws.
class UsageEventStore {
  UsageEventStore(this.dataDir, {this.rotateBytes = 5 * 1024 * 1024, this.keepOnRotate = 5000}) {
    lastId = _readLastId();
  }

  static const String fileName = 'usage-events.jsonl';

  final String dataDir;
  final int rotateBytes;
  final int keepOnRotate;

  /// Highest id present in the file at open time, then after each append.
  late int lastId;

  String get path => p.join(dataDir, fileName);

  void append(ToolEvent event) {
    try {
      final file = io.File(path);
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync('${jsonEncode(event.toRow())}\n',
          mode: io.FileMode.append, flush: true);
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
    final lines = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
    final tail = lines.length > keepOnRotate
        ? lines.sublist(lines.length - keepOnRotate)
        : lines;
    file.writeAsStringSync('${tail.join('\n')}\n', flush: true);
  }
}
