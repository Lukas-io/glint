import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint/glint.dart';
import 'package:test/test.dart';

Future<({HttpServer server, List<Map<String, Object?>> events})>
    _startMockCollector() async {
  final received = <Map<String, Object?>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(server.forEach((req) async {
    if (req.method == 'POST' && req.uri.path == '/v1/event') {
      final body = await utf8.decoder.bind(req).join();
      received.add(jsonDecode(body) as Map<String, Object?>);
      req.response.statusCode = 204;
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  }));
  return (server: server, events: received);
}

void main() {
  group('TelemetryClient', () {
    test('respects opt-out (no POST issued)', () async {
      final mock = await _startMockCollector();
      try {
        final cfg = GlintConfig()
          ..telemetryEndpoint = 'http://127.0.0.1:${mock.server.port}/v1/event';
        final client = TelemetryClient(cfg);
        client.noteAttach('ios');
        client.noteToolCall(name: 'tap', elapsedMs: 12);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(mock.events, isEmpty);
        await client.close();
      } finally {
        await mock.server.close(force: true);
      }
    });

    test('opt-in sends well-formed events', () async {
      final mock = await _startMockCollector();
      try {
        final cfg = GlintConfig()
          ..telemetryEndpoint = 'http://127.0.0.1:${mock.server.port}/v1/event'
          ..telemetryEnabled = true;
        final client = TelemetryClient(cfg);

        client.noteAttach('ios');
        client.noteToolCall(
          name: 'tap',
          elapsedMs: 42,
          errorKind: 'notHittable',
        );
        client.noteSession('open');

        // Wait for the detached POSTs to land.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (mock.events.length < 3 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(mock.events.length, 3);

        final byEvent = {
          for (final e in mock.events) e['event'] as String: e,
        };

        final attach = byEvent['attach']!;
        expect(attach['v'], 1);
        expect(attach['instance'], isA<String>());
        expect((attach['fields'] as Map)['platform'], 'ios');

        final tool = byEvent['tool_call']!;
        expect((tool['fields'] as Map)['name'], 'tap');
        expect((tool['fields'] as Map)['elapsedMs'], 42);
        expect((tool['fields'] as Map)['errorKind'], 'notHittable');
        expect(tool['platform'], 'ios',
            reason: 'platform set on attach should ride along subsequent events');

        final session = byEvent['session']!;
        expect((session['fields'] as Map)['op'], 'open');

        // All events share the same instance id.
        final instances =
            mock.events.map((e) => e['instance']).toSet();
        expect(instances.length, 1);

        await client.close();
      } finally {
        await mock.server.close(force: true);
      }
    });

    test('a transport failure never throws', () async {
      // Point at a closed port — connect will fail.
      final cfg = GlintConfig()
        ..telemetryEndpoint = 'http://127.0.0.1:1/v1/event'
        ..telemetryEnabled = true;
      final client = TelemetryClient(cfg);

      // Should not throw despite the dead endpoint.
      client.noteAttach('ios');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await client.close();
    });
  });
}
