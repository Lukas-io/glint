// Live verify for the config + report_issue tools.
//
//   dart run tool/verify_config_and_report.dart --vm-uri ws://...

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
        'clientInfo': {'name': 'verify_config', 'version': '0'},
      },
    }));
    await proc.stdin.flush();
    await incoming.firstWhere((x) => x['id'] == initId);
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    stdout.writeln('== config get (defaults) ==');
    final got = await call('config', {'op': 'get'});
    stdout.writeln(txt(got));

    stdout.writeln('\n== config set readyTimeoutMs=2500 ==');
    final set1 = await call('config',
        {'op': 'set', 'key': 'readyTimeoutMs', 'value': 2500});
    final after = sc(set1)['config'] as Map<String, Object?>;
    if (after['readyTimeoutMs'] != 2500) {
      stderr.writeln('expected readyTimeoutMs=2500; got ${after['readyTimeoutMs']}');
      failed++;
    }
    stdout.writeln('after set: readyTimeoutMs=${after['readyTimeoutMs']}');

    stdout.writeln('\n== config set invalid key (expect invalidArgument) ==');
    final bad = await call(
        'config', {'op': 'set', 'key': 'frobnicator', 'value': 1});
    final badKind = sc(bad)['errorKind'];
    if (badKind != 'invalidArgument') {
      stderr.writeln('expected invalidArgument; got $badKind');
      failed++;
    }
    stdout.writeln('errorKind=$badKind ✓');

    // Attach so report_issue can pick up the action log.
    stdout.writeln('\n== attach (so report_issue has context) ==');
    await call('attach', {
      'vmUri': opts['vm-uri'],
      'platform': 'ios',
      'device': opts['device'],
    });
    await call('tap', {'glintId': 'floating_action_button'});

    stdout.writeln('\n== report_issue dryRun (no actual filing) ==');
    final reported = await call('report_issue', {
      'type': 'feature',
      'title': '[verify] verify_config_and_report dry-run',
      'body': 'Smoke test body — checks that context auto-attach lands.',
      'includeContext': true,
      'dryRun': true,
    });
    final reportData = sc(reported);
    stdout.writeln(txt(reported));
    final composed = reportData['pasteBody'] as String?;
    if (composed == null) {
      stderr.writeln('expected pasteBody from dryRun');
      failed++;
    } else if (!composed.contains('Recent agent actions') ||
        !composed.contains('tap')) {
      stderr.writeln('expected Recent agent actions section with the tap entry');
      failed++;
    }
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0
      ? '\nCONFIG + REPORT: GREEN'
      : '\nCONFIG + REPORT: RED ($failed)');
  exit(failed == 0 ? 0 : 1);
}
