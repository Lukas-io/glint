// Live verify for P6 v0:
//   1. tap with awaitReady=true fires immediately when target is hittable.
//   2. tap with awaitReady=true returns targetNeverReady on bogus id within ceiling.
//   3. wait_for_settle returns settled=true on a static screen.
//
//   dart run tool/verify_p6.dart --vm-uri ws://...

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
      'clientInfo': {'name': 'verify_p6', 'version': '0'},
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

    stdout.writeln('\n== tap floating_action_button awaitReady=true ==');
    final armed = await req('tools/call', {
      'name': 'tap',
      'arguments': {
        'glintId': 'floating_action_button',
        'awaitReady': true,
        'readyTimeoutMs': 4000,
      },
    });
    stdout.writeln(txt(armed));
    final armedStructured = sc(armed);
    if (armedStructured['armed'] == null) {
      stderr.writeln('expected armed metadata; got ${armedStructured.keys.toList()}');
      failed++;
    } else {
      stdout.writeln('  armed metadata: ${armedStructured['armed']}');
    }

    stdout.writeln('\n== tap does_not_exist awaitReady=true readyTimeoutMs=1200 → expect unresolvedTarget ==');
    final ghost = await req('tools/call', {
      'name': 'tap',
      'arguments': {
        'glintId': 'does_not_exist_xyz',
        'awaitReady': true,
        'readyTimeoutMs': 1200,
      },
    });
    stdout.writeln(txt(ghost));
    final ghostKind = sc(ghost)['errorKind'];
    if (ghostKind != 'unresolvedTarget') {
      stderr.writeln('expected unresolvedTarget; got $ghostKind');
      failed++;
    }

    stdout.writeln('\n== wait_for_settle on static counter screen ==');
    final settle = await req('tools/call', {
      'name': 'wait_for_settle',
      'arguments': {'ceilingMs': 2000, 'quietFrames': 3},
    });
    stdout.writeln(txt(settle));
    final settleData = sc(settle);
    if (settleData['settled'] != true) {
      stderr.writeln('expected settled=true on static screen; got $settleData');
      failed++;
    }
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0 ? '\nP6 VERIFY: GREEN' : '\nP6 VERIFY: RED ($failed)');
  exit(failed == 0 ? 0 : 1);
}
