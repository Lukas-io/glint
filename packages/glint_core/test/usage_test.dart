import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart';
import 'package:test/test.dart';

class _FakeSource implements UsageEventSource {
  final rows = <Map<String, Object?>>[];

  void add(String tool, {String outcome = 'ok', int? bytes}) => rows.add({
        'id': rows.length + 1,
        'ts_ms': 1000 + rows.length,
        'correlation_id': 'p-1',
        'tool': tool,
        'outcome': outcome,
        'result_bytes': bytes,
      });

  @override
  List<Map<String, Object?>> eventsAfter(int afterId, {required int limit}) =>
      rows.where((r) => (r['id'] as int) > afterId).take(limit).toList();

  @override
  int get maxEventId => rows.isEmpty ? 0 : rows.last['id'] as int;
}

void main() {
  late Directory dir;
  late _FakeSource source;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('usage');
    source = _FakeSource();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  UsageShipper shipper(Map<String, String> env) => UsageShipper(
        source: source,
        switches: const TelemetrySwitches('TEST_'),
        identity: () => {'version': 'test/1.0.0', 'isAot': false},
        userAgent: 'test',
        dataDir: () => dir.path,
        env: () => env,
        endpoint: '',
      );

  const optedIn = {'TEST_TELEMETRY': 'on'};

  test('ships once to the audit log, then only what is new', () async {
    source
      ..add('a')
      ..add('b');
    final first = await shipper(optedIn).ship();
    expect(first.shipped, isTrue);
    expect(first.events, 2);
    expect(AuditLog.verify(dir.path).totalEntries, 1);
    final payload = jsonDecode(AuditLog.readAll(dir.path).single!.decodePayload()) as Map;
    expect(payload['version'], 'test/1.0.0');
    expect(payload['isAot'], isFalse);

    expect((await shipper(optedIn).ship()).shipped, isFalse);
    source.add('c');
    final third = await shipper(optedIn).ship();
    expect((third.fromEventId, third.toEventId, third.events), (2, 3, 1));
  });

  test('a store reset below the watermark ships from the start instead of dropping events', () async {
    source.add('a');
    await shipper(optedIn).ship();
    File('${dir.path}/${UsageShipper.stateFileName}')
        .writeAsStringSync('{"lastShippedEventId": 99, "shipCount": 1}');
    expect(shipper(optedIn).unshippedCount(), 1);
  });

  test('nothing is sent without opt-in, but a dry run shows the payload', () async {
    source.add('a');
    final off = await shipper(const {}).ship();
    expect(off.shipped, isFalse);
    expect(off.message, contains('TEST_TELEMETRY=on'));
    final dry = await shipper(const {}).ship(dryRun: true);
    expect(dry.dryRun, isTrue);
    expect(jsonDecode(dry.payloadJson!)['kind'], 'usage_rollup');
    expect(AuditLog.verify(dir.path).totalEntries, 0);
  });

  test('DO_NOT_TRACK and NO_USAGE stop a ship', () async {
    source.add('a');
    expect((await shipper({...optedIn, 'DO_NOT_TRACK': '1'}).ship()).shipped, isFalse);
    expect((await shipper({...optedIn, 'TEST_NO_USAGE': 'true'}).ship()).message,
        contains('usage recording is off'));
  });

  test('tokens come from stored estimates, else from result bytes', () {
    final stats = summarizeUsage([
      {'correlation_id': 'c', 'tool': 'x', 'outcome': 'ok', 'result_bytes': 400},
      {'correlation_id': 'c', 'tool': 'x', 'outcome': 'ok', 'result_bytes': 400, 'estimated_tokens': 7},
    ]);
    expect(stats['totalEstimatedTokens'], 107);
  });

  test('a turn ends after the gap', () {
    final turns = TurnTracker(gapMs: 1000);
    final a = turns.correlationIdFor(0);
    expect(turns.correlationIdFor(900), a);
    final b = turns.correlationIdFor(3000);
    expect(b, isNot(a));
    expect(b.split('-').first, a.split('-').first);
  });

  test('outcome and argument names', () {
    expect(usageOutcome(isError: true), 'error');
    expect(usageOutcome(isError: false, structured: {'count': 0}), 'empty');
    expect(usageOutcome(isError: false, structured: {'count': 3}), 'ok');
    expect(usageArgKeys({'b': 'secret', 'a': 1}), ['a', 'b']);
  });
}
