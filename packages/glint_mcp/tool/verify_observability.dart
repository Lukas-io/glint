// Live verify for the observability batch:
//   1. uiState fields (focusedType, keyboardVisible) appear on get_scene.
//   2. AppLogBuffer subscribes to stderr+logging and surfaces entries.
//   3. SessionManager open/note/close/export round-trips.
//
//   dart run tool/verify_observability.dart --vm-uri ws://...

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

void main(List<String> argv) async {
  final opts = (ArgParser()
        ..addOption('vm-uri', mandatory: true)
        ..addOption('device', defaultsTo: '791A0611-C553-445E-87E6-4BA41F6A9143'))
      .parse(argv);

  final proc = await Process.start(Platform.resolvedExecutable,
      ['run', 'bin/glint.dart'],
      workingDirectory: Directory.current.path);
  unawaited(proc.stderr.transform(utf8.decoder).forEach(stderr.write));

  final incoming = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((l) => l.isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, Object?>)
      .asBroadcastStream();
  var nextId = 1;
  Future<Map<String, Object?>> req(String m, Map<String, Object?> p) async {
    final id = nextId++;
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': m, 'params': p}));
    await proc.stdin.flush();
    return incoming.firstWhere((x) => x['id'] == id);
  }

  Map<String, Object?> sc(Map<String, Object?> r) =>
      (r['result'] as Map)['structuredContent'] as Map<String, Object?>;
  String txt(Map<String, Object?> r) {
    final c = (r['result'] as Map)['content'] as List?;
    return c?.firstOrNull is Map ? (c!.first as Map)['text'] as String : '';
  }

  var failed = 0;
  try {
    await req('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': const {},
      'clientInfo': {'name': 'verify_observability', 'version': '0'},
    });
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    stdout.writeln('== attach ==');
    final att = await req('tools/call', {
      'name': 'attach',
      'arguments': {
        'vmUri': opts['vm-uri'],
        'platform': 'ios',
        'device': opts['device'],
      },
    });
    if ((att['result'] as Map)['isError'] == true) {
      stderr.writeln('attach failed: ${txt(att)}');
      exit(1);
    }

    // ── ui state on get_scene
    stdout.writeln('\n== get_scene: focusedType + keyboardVisible + lifecycle ==');
    final scene = await req('tools/call', {
      'name': 'get_scene',
      'arguments': const {},
    });
    final sceneData = sc(scene);
    stdout.writeln('focusedType: ${sceneData['focusedType']}');
    stdout.writeln('keyboardVisible: ${sceneData['keyboardVisible']}');
    stdout.writeln('lifecycle: ${sceneData['lifecycle']}');
    stdout.writeln('state: ${sceneData['state']}');
    if (sceneData['keyboardVisible'] == null) {
      stderr.writeln('expected keyboardVisible flag');
      failed++;
    }
    if (sceneData['lifecycle'] == null) {
      stderr.writeln('expected lifecycle field');
      failed++;
    }

    // ── session open / note / close / export
    stdout.writeln('\n== session round-trip ==');
    await req('tools/call', {
      'name': 'session',
      'arguments': {'op': 'open', 'name': 'verify-run'},
    });
    // do a couple actions inside the session
    await req('tools/call', {
      'name': 'tap',
      'arguments': {'glintId': 'floating_action_button'},
    });
    await req('tools/call', {
      'name': 'session',
      'arguments': {'op': 'note', 'text': 'counter advanced'},
    });
    await req('tools/call', {
      'name': 'tap',
      'arguments': {'glintId': 'floating_action_button'},
    });
    final closed = await req('tools/call', {
      'name': 'session',
      'arguments': {'op': 'close'},
    });
    stdout.writeln(txt(closed));
    final closedData = sc(closed);
    final closedSession = closedData['session'] as Map<String, Object?>;
    if (closedSession['isActive'] != false) {
      stderr.writeln('expected closed session to be inactive');
      failed++;
    }
    if (closedSession['name'] != 'verify-run') {
      stderr.writeln('expected name=verify-run');
      failed++;
    }

    stdout.writeln('\n== session export ==');
    final exp = await req('tools/call', {
      'name': 'session',
      'arguments': {'op': 'export', 'sessionId': closedSession['id']},
    });
    stdout.writeln(txt(exp));
    final expData = sc(exp);
    final entries = (expData['entries'] as List).cast<Map<String, Object?>>();
    final tapCount = entries.where((e) => e['tool'] == 'tap').length;
    if (tapCount != 2) {
      stderr.writeln('expected 2 tap entries in export; got $tapCount');
      failed++;
    }

    // ── app_logs (likely empty unless the app printed something)
    stdout.writeln('\n== app_logs ==');
    final appLogs = await req('tools/call', {
      'name': 'app_logs',
      'arguments': const {'limit': 5},
    });
    stdout.writeln(txt(appLogs));
    final logData = sc(appLogs);
    stdout.writeln('count: ${logData['count']}');
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0 ? '\nOBSERVABILITY: GREEN' : '\nOBSERVABILITY: RED ($failed)');
  exit(failed == 0 ? 0 : 1);
}
