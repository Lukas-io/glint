import 'dart:convert';
import 'dart:io';

import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('UsageRecorder', () {
    test('opt-out: record is a no-op', () {
      final r = UsageRecorder.config(enabled: false);
      r.record(
        tool: 'tap',
        outcome: ToolOutcome.ok,
        argKeys: const ['glintId'],
        durationMs: 10,
        resultBytes: 50,
      );
      expect(r.length, 0);
    });

    test('opt-in: record appends; ids are 1-based', () {
      final r = UsageRecorder.config(enabled: true);
      for (var i = 0; i < 3; i++) {
        r.record(
          tool: 'tap',
          outcome: ToolOutcome.ok,
          argKeys: const ['glintId'],
          durationMs: 10,
          resultBytes: 50,
        );
      }
      expect(r.length, 3);
      // First id=1, nextId=4 after three records (1-based).
      expect(r.nextId, 4);
    });

    test('correlationIdFor rolls over after the idle gap', () {
      final r = UsageRecorder.config(enabled: true, gapMs: 1000);
      final a = r.correlationIdFor(1000);
      final b = r.correlationIdFor(1500);
      final c = r.correlationIdFor(3000); // gap exceeded
      expect(a, b);
      expect(c, isNot(a));
    });

    test('eventsAfterId filters by watermark', () {
      final r = UsageRecorder.config(enabled: true);
      for (var i = 0; i < 5; i++) {
        r.record(
          tool: 't',
          outcome: ToolOutcome.ok,
          argKeys: const [],
          durationMs: i,
          resultBytes: 0,
        );
      }
      // ids assigned 1..5; afterId=2 yields ids 3, 4, 5.
      final rows = r.eventsAfterId(2);
      expect(rows.length, 3);
      expect((rows.first['id'] as int), 3);
    });

    test('argKeysFrom returns sorted keys, never values', () {
      final keys = UsageRecorder.argKeysFrom({
        'zeta': 1,
        'alpha': 'secret',
        'mu': [1, 2, 3],
      });
      expect(keys, ['alpha', 'mu', 'zeta']);
    });

    test('outcomeFrom maps cleanly', () {
      expect(UsageRecorder.outcomeFrom(isError: true), ToolOutcome.error);
      expect(UsageRecorder.outcomeFrom(isError: false), ToolOutcome.ok);
      expect(
        UsageRecorder.outcomeFrom(isError: false, structured: {'count': 0}),
        ToolOutcome.empty,
      );
    });
  });

  group('summarizeUsage', () {
    test('produces per-tool counts + p50/p95 + transitions', () {
      final rows = [
        {
          'correlation_id': 't1',
          'tool': 'tap',
          'outcome': 'ok',
          'duration_ms': 10,
          'result_bytes': 0,
        },
        {
          'correlation_id': 't1',
          'tool': 'get_scene',
          'outcome': 'ok',
          'duration_ms': 30,
          'result_bytes': 1000,
        },
        {
          'correlation_id': 't2',
          'tool': 'tap',
          'outcome': 'error',
          'duration_ms': 50,
          'result_bytes': 0,
        },
      ];
      final out = summarizeUsage(rows);
      expect(out['totalEvents'], 3);
      expect(out['totalTurns'], 2);
      final tools = out['tools'] as List;
      expect(tools.length, 2);
      final tap = tools.firstWhere((t) => (t as Map)['tool'] == 'tap') as Map;
      expect(tap['count'], 2);
      expect(tap['error'], 1);
      final trans = out['transitions'] as List;
      expect(trans.length, 1);
      expect((trans.first as Map)['from'], 'tap');
      expect((trans.first as Map)['to'], 'get_scene');
    });
  });

  group('AuditLog', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('glint-audit-test-');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('append + verify intact on a fresh chain', () {
      AuditLog.append(tmp.path, '{"a":1}');
      AuditLog.append(tmp.path, '{"b":2}');
      AuditLog.append(tmp.path, '{"c":3}');
      final res = AuditLog.verify(tmp.path);
      expect(res.intact, true);
      expect(res.totalEntries, 3);
    });

    test('verify detects payload tampering', () {
      AuditLog.append(tmp.path, '{"a":1}');
      AuditLog.append(tmp.path, '{"b":2}');
      final file = File('${tmp.path}/${AuditLog.fileName}');
      final lines = file.readAsLinesSync();
      // Tamper the payload of line 1 (keep structure but change content).
      final parts = lines[1].split('|');
      parts[2] = base64.encode(utf8.encode('{"b":999}'));
      lines[1] = parts.join('|');
      file.writeAsStringSync('${lines.join('\n')}\n');
      final res = AuditLog.verify(tmp.path);
      expect(res.intact, false);
      expect(res.brokenAtIndex, 1);
    });
  });

  group('UsageReporter', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('glint-ship-test-');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('ship returns no-new-events when recorder is empty', () async {
      final r = UsageRecorder.config(enabled: true);
      final reporter = UsageReporter(r);
      final res = await reporter.ship(dataDir: tmp.path);
      expect(res.shipped, false);
      expect(res.events, 0);
    });

    test('dryRun composes a valid payload without writing', () async {
      final r = UsageRecorder.config(enabled: true);
      r.record(
        tool: 'tap',
        outcome: ToolOutcome.ok,
        argKeys: const ['glintId'],
        durationMs: 12,
        resultBytes: 100,
      );
      final reporter = UsageReporter(r);
      final res =
          await reporter.ship(dataDir: tmp.path, dryRun: true);
      expect(res.shipped, false);
      expect(res.dryRun, true);
      expect(res.payloadJson, isNotNull);
      final payload =
          jsonDecode(res.payloadJson!) as Map<String, Object?>;
      expect(payload['kind'], 'usage_rollup');
      expect(payload['version'], 'glint/0.0.1');
      final tools = payload['tools'] as List;
      expect(tools.length, 1);
      expect((tools.first as Map)['tool'], 'tap');
      // audit log not touched on dry-run
      final auditFile = File('${tmp.path}/${AuditLog.fileName}');
      expect(auditFile.existsSync(), false);
    });

    test('ship writes audit log even if POST fails', () async {
      final r = UsageRecorder.config(enabled: true);
      r.record(
        tool: 'tap',
        outcome: ToolOutcome.ok,
        argKeys: const [],
        durationMs: 1,
        resultBytes: 0,
      );
      final reporter = UsageReporter(r);
      // Use a dead endpoint so POST fails fast.
      final res = await reporter.ship(
        dataDir: tmp.path,
        endpointOverride: 'http://127.0.0.1:1/v1/telemetry',
      );
      expect(res.shipped, true);
      expect(res.posted, false);
      final auditFile = File('${tmp.path}/${AuditLog.fileName}');
      expect(auditFile.existsSync(), true);
      expect(AuditLog.verify(tmp.path).intact, true);
    });

    test('watermark advances; double-ship is a no-op', () async {
      final r = UsageRecorder.config(enabled: true);
      r.record(
        tool: 'tap',
        outcome: ToolOutcome.ok,
        argKeys: const [],
        durationMs: 1,
        resultBytes: 0,
      );
      final reporter = UsageReporter(r);
      final first = await reporter.ship(
        dataDir: tmp.path,
        endpointOverride: 'http://127.0.0.1:1/v1/telemetry',
      );
      expect(first.shipped, true);
      final second = await reporter.ship(
        dataDir: tmp.path,
        endpointOverride: 'http://127.0.0.1:1/v1/telemetry',
      );
      expect(second.shipped, false);
      expect(second.events, 0);
    });
  });
}
