// Spawns `bin/glint.dart` over a stdio pipe, runs the MCP handshake,
// asks for the tool list, and asserts the six P4 v0 tools are present
// with the expected input schemas. No live VM is needed — we don't
// dispatch any tool that touches a real device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('glint MCP server (stdio)', () {
    late Process proc;
    late Stream<Map<String, Object?>> incoming;
    var nextId = 1;

    setUp(() async {
      proc = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/glint.dart'],
        workingDirectory: Directory.current.path,
      );
      incoming = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .asBroadcastStream();
      // Drain stderr so any startup errors surface in the test log.
      unawaited(proc.stderr.transform(utf8.decoder).forEach(stderr.write));
    });

    tearDown(() async {
      proc.kill();
      await proc.exitCode;
    });

    Future<Map<String, Object?>> request(
        String method, Map<String, Object?> params) async {
      final id = nextId++;
      proc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }));
      await proc.stdin.flush();
      return incoming.firstWhere(
        (m) => m['id'] == id,
        orElse: () => <String, Object?>{},
      );
    }

    test('initialize → tools/list returns the P4 v0 tool set', () async {
      final initResp = await request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': const {},
        'clientInfo': {'name': 'glint-test', 'version': '0'},
      });
      expect(initResp['error'], isNull,
          reason: 'initialize must succeed: $initResp');

      // The initialize result must carry the Module D instruction text.
      final initResult = initResp['result'] as Map<String, Object?>;
      final instructions = initResult['instructions'] as String?;
      expect(instructions, isNotNull);
      expect(instructions, contains('## Workflow'));
      expect(instructions, contains('## Recovery'));

      // Send the initialized notification (no response expected).
      proc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }));
      await proc.stdin.flush();

      final listResp = await request('tools/list', const {});
      final result = listResp['result'] as Map<String, Object?>;
      final tools = (result['tools'] as List).cast<Map<String, Object?>>();
      final names = tools.map((t) => t['name']).toSet();

      expect(
        names,
        containsAll([
          'attach',
          'get_scene',
          'resolve',
          'tap',
          'long_press',
          'swipe',
          'drag',
          'scroll',
          'scroll_to_find',
          'type',
          'hardware_button',
          'wait_for_settle',
          'logs',
        ]),
      );
    });

    test('calling get_scene before attach returns SessionNotAttached',
        () async {
      await request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': const {},
        'clientInfo': {'name': 'glint-test', 'version': '0'},
      });
      proc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }));
      await proc.stdin.flush();

      final resp = await request('tools/call', {
        'name': 'get_scene',
        'arguments': const {},
      });
      final result = resp['result'] as Map<String, Object?>;
      expect(result['isError'], true);
      final structured = result['structuredContent'] as Map<String, Object?>;
      expect(structured['errorKind'], 'sessionNotAttached');
    });
  });
}
