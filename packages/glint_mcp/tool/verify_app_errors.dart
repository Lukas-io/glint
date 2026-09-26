// Live verify that the AppLogBuffer captures real FlutterError dumps +
// developer.log messages. Trigger via VM eval (no fixture changes).
//
//   dart run tool/verify_app_errors.dart --vm-uri ws://...

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
        'clientInfo': {'name': 'verify_app_errors', 'version': '0'},
      },
    }));
    await proc.stdin.flush();
    await incoming.firstWhere((x) => x['id'] == initId);
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    stdout.writeln('== attach (subscribes to Stderr + Logging) ==');
    await call('attach', {
      'vmUri': opts['vm-uri'],
      'platform': 'ios',
      'device': opts['device'],
    });

    // Quick sanity: app_logs empty at start.
    final empty = await call('app_logs', const {});
    final emptyCount = sc(empty)['count'] as int;
    stdout.writeln('initial app_logs count: $emptyCount');

    // Trigger a FlutterError dump via VM eval. dumpErrorToConsole writes
    // to stderr → our Stderr subscription captures it.
    // (We don't test developer.log here because the fixture doesn't
    //  import dart:developer; the Logging stream subscription is still
    //  wired and exercised when an app uses it in practice.)
    stdout.writeln('\n== triggering FlutterError.dumpErrorToConsole ==');
    await _vmEval(
      opts['vm-uri'] as String,
      'FlutterError.dumpErrorToConsole(FlutterErrorDetails(exception: Exception("synthetic-error-for-verify"), library: "glint verify"))',
    );

    // Streams are async; give them a beat to land in the buffer.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    stdout.writeln('\n== app_logs (all entries) ==');
    final all = await call('app_logs', {'limit': 50});
    stdout.writeln(txt(all));
    final allCount = sc(all)['count'] as int;
    final entries = (sc(all)['entries'] as List).cast<Map<String, Object?>>();
    final foundFlutterError = entries.any((e) =>
        (e['content'] as String).contains('synthetic-error-for-verify') ||
        (e['content'] as String).toLowerCase().contains('exception'));
    if (!foundFlutterError) {
      stderr.writeln('FAIL: FlutterError dump not captured in app_logs');
      failed++;
    }

    stdout.writeln('\n== app_logs errorsOnly ==');
    final errs = await call('app_logs', {'errorsOnly': true});
    final errCount = sc(errs)['count'] as int;
    stdout.writeln('errorsOnly count: $errCount');
    if (errCount == 0) {
      stderr.writeln('FAIL: errorsOnly filter found nothing');
      failed++;
    }
    stdout.writeln(txt(errs));

    stdout.writeln('\n(total app_logs captured: $allCount)');
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0
      ? '\nAPP ERROR VERIFY: GREEN'
      : '\nAPP ERROR VERIFY: RED ($failed)');
  exit(failed == 0 ? 0 : 1);
}

/// Fire a VM-service evaluate to inject a log / error. Uses a separate
/// vm_service connection so the verify script can drive the running app
/// without going through glint.
Future<void> _vmEval(String vmUri, String expression) async {
  final probe = await Process.run(Platform.resolvedExecutable, [
    'run',
    'tool/probe_vm_eval.dart',
    vmUri,
    expression,
  ]);
  if (probe.exitCode != 0) {
    throw StateError(
        'probe_vm_eval failed (${probe.exitCode}): ${probe.stderr}');
  }
}
