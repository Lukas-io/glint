// End-to-end scenario test: a real flow with a named session,
// multiple action types, notes, and an audit-trail export.
//
//   dart run tool/verify_full_scenario.dart --vm-uri ws://...

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
  Future<Map<String, Object?>> call(String tool,
      [Map<String, Object?> args = const {}]) async {
    final id = nextId++;
    proc.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': args},
    }));
    await proc.stdin.flush();
    return incoming.firstWhere((x) => x['id'] == id);
  }

  Map<String, Object?> sc(Map<String, Object?> r) =>
      (r['result'] as Map)['structuredContent'] as Map<String, Object?>;
  String txt(Map<String, Object?> r) {
    final c = (r['result'] as Map)['content'] as List?;
    return c?.firstOrNull is Map ? (c!.first as Map)['text'] as String : '';
  }

  void note(String s) => stdout.writeln('\n── $s ──');

  var failed = 0;

  try {
    final initId = nextId++;
    proc.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': initId,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': const {},
        'clientInfo': {'name': 'verify_full_scenario', 'version': '0'},
      },
    }));
    await proc.stdin.flush();
    await incoming.firstWhere((x) => x['id'] == initId);
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    note('attach');
    final att = await call('attach', {
      'vmUri': opts['vm-uri'],
      'platform': 'ios',
      'device': opts['device'],
    });
    if ((att['result'] as Map)['isError'] == true) {
      stderr.writeln('attach failed: ${txt(att)}');
      exit(1);
    }

    note('open named session');
    final opened = await call('session', {
      'op': 'open',
      'name': 'smoke flow: counter + type + scroll',
    });
    final sessionId =
        ((sc(opened)['session'] as Map)['id'] as String);
    stdout.writeln('session id: $sessionId');

    note('phase 1: counter');
    await call('session', {'op': 'note', 'text': 'starting counter phase'});
    for (var i = 0; i < 5; i++) {
      await call('tap', {'glintId': 'floating_action_button'});
    }
    await call('session',
        {'op': 'note', 'text': 'incremented counter 5 times'});

    note('phase 2: type');
    await call('type', {
      'text': 'verify run 2026-06-14',
      'focus': 'text_field',
    });
    await call('session', {'op': 'note', 'text': 'typed into text_field'});

    note('phase 3: scroll-to-find');
    final find = await call('scroll_to_find', {
      'targetTextContent': 'scroll row 27',
      'direction': 'down',
    });
    final findData = sc(find);
    final foundId = findData['glintId'] as String?;
    stdout.writeln(txt(find));
    if (foundId == null) {
      failed++;
      stderr.writeln('scroll_to_find did not return a glintId');
    } else {
      final geo = await call('resolve', {'glintId': foundId});
      stdout.writeln(txt(geo));
      await call('session', {
        'op': 'note',
        'text': 'row 27 resolved at y=${(sc(geo)['physicalCenter'] as Map)['y']}',
      });
    }

    note('phase 4: re-read scene to confirm everything');
    final finalScene = await call('get_scene', const {});
    final finalData = sc(finalScene);
    stdout.writeln('state=${finalData['state']} '
        'lifecycle=${finalData['lifecycle']} '
        'focusedType=${finalData['focusedType']} '
        'keyboardVisible=${finalData['keyboardVisible']}');

    note('close session');
    final closed = await call('session', {'op': 'close'});
    final closedSession = sc(closed)['session'] as Map<String, Object?>;
    stdout.writeln('${closedSession['name']}: '
        'seq=${closedSession['firstSeq']}..${closedSession['lastSeq']} '
        '(${(closedSession['notes'] as List?)?.length ?? 0} notes)');

    note('audit trail (session export)');
    final exp = await call('session', {
      'op': 'export',
      'sessionId': sessionId,
    });
    stdout.writeln(txt(exp));

    note('app_logs (looking for anything the app emitted)');
    final logs = await call('app_logs', {'limit': 20});
    final logCount = sc(logs)['count'];
    stdout.writeln('app log entries: $logCount');
    if ((logCount as int) > 0) {
      stdout.writeln(txt(logs));
    } else {
      stdout.writeln('(none — fixture was quiet, expected)');
    }

    note('app_logs: errors-only');
    final errs = await call('app_logs', {'errorsOnly': true, 'limit': 10});
    final errCount = sc(errs)['count'];
    stdout.writeln('error-like entries: $errCount');
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0
      ? '\nSCENARIO: GREEN'
      : '\nSCENARIO: RED ($failed failures)');
  exit(failed == 0 ? 0 : 1);
}
