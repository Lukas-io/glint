import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('ActionLog', () {
    test('records sequential entries with allocated sequence numbers', () {
      final log = ActionLog();
      for (var i = 0; i < 3; i++) {
        log.record(SuccessEntry(
          sequence: log.allocateSequence(),
          timestamp: DateTime(2026, 6, 14, 12, i),
          tool: 'tap',
          elapsedMs: 10,
          summary: 'ok $i',
        ));
      }
      final entries = log.query().toList();
      expect(entries.map((e) => e.sequence), [0, 1, 2]);
    });

    test('caps at capacity, oldest drop off', () {
      final log = ActionLog(capacity: 2);
      for (var i = 0; i < 5; i++) {
        log.record(SuccessEntry(
          sequence: log.allocateSequence(),
          timestamp: DateTime(2026, 6, 14, 12, i),
          tool: 'tap',
          elapsedMs: 5,
          summary: 'ok $i',
        ));
      }
      final entries = log.query().toList();
      expect(entries.length, 2);
      expect(entries.first.sequence, 3);
      expect(entries.last.sequence, 4);
    });

    test('query filters by tool, failures, sinceSeq', () {
      final log = ActionLog();
      log.record(SuccessEntry(
          sequence: log.allocateSequence(),
          timestamp: DateTime(2026, 6, 14, 12),
          tool: 'tap',
          elapsedMs: 1,
          summary: 'a'));
      log.record(FailureEntry(
          sequence: log.allocateSequence(),
          timestamp: DateTime(2026, 6, 14, 12),
          tool: 'type',
          elapsedMs: 1,
          summary: 'b',
          errorKind: GlintErrorKind.invalidArgument));
      log.record(SuccessEntry(
          sequence: log.allocateSequence(),
          timestamp: DateTime(2026, 6, 14, 12),
          tool: 'tap',
          elapsedMs: 1,
          summary: 'c'));

      expect(log.query(toolFilter: 'tap').length, 2);
      expect(log.query(failuresOnly: true).length, 1);
      expect(log.query(sinceSeq: 1).map((e) => e.sequence), [1, 2]);
    });
  });

  group('LogRenderer', () {
    test('renders timestamps relative to the first entry', () {
      final origin = DateTime(2026, 6, 14, 12);
      final entries = <LogEntry>[
        SuccessEntry(
          sequence: 0,
          timestamp: origin,
          tool: 'tap',
          elapsedMs: 12,
          summary: 'tapped fab',
          args: const {'glintId': 'fab'},
        ),
        FailureEntry(
          sequence: 1,
          timestamp: origin.add(const Duration(milliseconds: 450)),
          tool: 'tap',
          elapsedMs: 30,
          summary: 'no such id',
          errorKind: GlintErrorKind.unresolvedTarget,
          args: const {'glintId': 'missing'},
        ),
      ];
      final out = const LogRenderer().render(entries);
      expect(out, contains('[t+0ms]'));
      expect(out, contains('tap(glintId=fab) → tapped fab [12ms]'));
      expect(out, contains('[t+450ms]'));
      expect(out, contains('FAIL unresolvedTarget'));
    });
  });
}
