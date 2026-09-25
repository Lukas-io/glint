import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

/// Drives fixtures/counter_app through glint's MCP server the way an agent would: attach, read, tap, type, scroll; exits non-zero naming the first step that failed.
Future<void> main(List<String> args) async {
  final opts = (ArgParser()
        ..addOption('vm-uri', help: 'VM service URI of the running fixture; omit to let attach find it.')
        ..addOption('platform', allowed: ['ios', 'android'])
        ..addOption('device', help: 'Simulator UDID or adb serial.')
        ..addOption('adb-path'))
      .parse(args);
  final server = await _Server.start();
  var failed = false;
  Future<Map<String, Object?>> step(String name, String tool, Map<String, Object?> input,
      bool Function(Map<String, Object?> result, String text) check) async {
    final (result, text) = await server.call(tool, input);
    final passed = result['isError'] != true && check(result, text);
    stdout.writeln('${passed ? 'PASS' : 'FAIL'}  $name');
    if (!passed) {
      failed = true;
      stdout.writeln(text.split('\n').take(40).map((l) => '      $l').join('\n'));
    }
    return result;
  }

  try {
    await step('attach', 'attach', {
      if (opts['vm-uri'] != null) 'vmUri': opts['vm-uri'],
      if (opts['platform'] != null) 'platform': opts['platform'],
      if (opts['device'] != null) 'device': opts['device'],
      if (opts['adb-path'] != null) 'adbPath': opts['adb-path'],
    }, (r, text) =>
        text.contains('attached') &&
        (opts['platform'] != 'ios' || (_data(r)['toolchain'] as Map?)?['actionsAllowed'] == true));
    if (failed) exit(1);

    var scene = '';
    await step('get_scene shows the counter at 0', 'get_scene', {}, (_, text) {
      scene = text;
      return text.contains('You have pushed the button') && RegExp(r'"0"').hasMatch(text);
    });
    final fab = _idOnLine(scene, (l) => l.contains('button') && l.contains('floating_action_button'));
    final field = _idOnLine(scene, (l) => l.contains('input') && l.contains('glint type target'));

    await step('tap + raises the counter to 1', 'tap', {'glintId': fab ?? 'missing-fab'},
        (r, _) => _data(r)['changed'] == true);
    await step('get_scene shows the counter at 1', 'get_scene', {},
        (_, text) => RegExp(r'"1"').hasMatch(text));

    await step('type into the text field', 'type',
        {'focus': field ?? 'missing-field', 'text': 'hello glint'}, (r, _) => _data(r)['changed'] == true);
    await step('the field holds the typed text', 'get_scene', {'glintId': field ?? 'missing-field'},
        (_, text) => text.contains('hello glint'));

    await step('scroll down moves the page', 'scroll', {'direction': 'down'},
        (r, _) => _data(r)['changed'] == true);
  } finally {
    await server.close();
  }
  stdout.writeln(failed ? 'device check FAILED' : 'device check passed');
  exit(failed ? 1 : 0);
}

Map<String, Object?> _data(Map<String, Object?> result) =>
    (result['structuredContent'] as Map?)?.cast<String, Object?>() ?? const {};

/// The glintId on the first scene line [match] accepts (the token after the role).
String? _idOnLine(String scene, bool Function(String line) match) {
  for (final line in scene.split('\n')) {
    if (!match(line)) continue;
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 3) return parts[2];
  }
  return null;
}

class _Server {
  _Server(this._proc, this._replies);

  final Process _proc;
  final Stream<Map<String, Object?>> _replies;
  var _nextId = 1;

  static Future<_Server> start() async {
    final proc = await Process.start(Platform.resolvedExecutable, ['run', 'bin/glint.dart'],
        environment: {'GLINT_NO_TELEMETRY': 'true', 'GLINT_NO_UPDATE_CHECK': 'true'});
    unawaited(proc.stderr.transform(utf8.decoder).forEach(stderr.write));
    final replies = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.startsWith('{'))
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .asBroadcastStream();
    final server = _Server(proc, replies);
    await server._request('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': const {},
      'clientInfo': {'name': 'device-check', 'version': '0'},
    });
    proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    return server;
  }

  Future<Map<String, Object?>> _request(String method, Map<String, Object?> params) async {
    final id = _nextId++;
    _proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    final reply = await _replies.firstWhere((m) => m['id'] == id).timeout(const Duration(minutes: 4));
    return (reply['result'] as Map?)?.cast<String, Object?>() ?? {'isError': true, 'error': reply['error']};
  }

  /// A tool's result and its text content.
  Future<(Map<String, Object?>, String)> call(String tool, Map<String, Object?> input) async {
    final result = await _request('tools/call', {'name': tool, 'arguments': input});
    final text = ((result['content'] as List?) ?? const [])
        .whereType<Map>()
        .map((c) => c['text'] as String? ?? '')
        .join('\n');
    return (result, text.isEmpty ? jsonEncode(result) : text);
  }

  Future<void> close() async {
    await _proc.stdin.close();
    await _proc.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      _proc.kill();
      return -1;
    });
  }
}
