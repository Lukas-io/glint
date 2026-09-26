// P4 live verification gate. Spawns bin/glint.dart over stdio,
// runs the JSON-RPC handshake, then drives the counter fixture
// through attach → get_scene → tap (counter increments) → swipe (scroll)
// → type (TextField). Each step prints the tool result so a human
// can eyeball the envelope shape.
//
//   dart run tool/verify_p4.dart --vm-uri ws://...

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

void main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('platform', defaultsTo: 'ios')
    ..addOption('device', defaultsTo: '791A0611-C553-445E-87E6-4BA41F6A9143');
  final opts = parser.parse(argv);

  final proc = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'bin/glint.dart'],
    workingDirectory: Directory.current.path,
  );
  unawaited(proc.stderr.transform(utf8.decoder).forEach(stderr.write));

  final incoming = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((l) => l.isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, Object?>)
      .asBroadcastStream();
  var nextId = 1;

  Future<Map<String, Object?>> req(
      String method, Map<String, Object?> params) async {
    final id = nextId++;
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    await proc.stdin.flush();
    return incoming.firstWhere((m) => m['id'] == id);
  }

  void note(String s) => stdout.writeln('\n== $s ==');
  void print1(Map<String, Object?> resp) {
    final result = resp['result'] as Map<String, Object?>?;
    if (result == null) {
      stdout.writeln('ERROR ${jsonEncode(resp['error'])}');
      return;
    }
    final isError = result['isError'] == true;
    final content = result['content'] as List?;
    final text = content?.firstOrNull is Map
        ? (content!.first as Map)['text']
        : '';
    stdout.writeln('isError=$isError');
    stdout.writeln(text);
    if (isError) {
      stdout.writeln('structuredContent: ${jsonEncode(result['structuredContent'])}');
    }
  }

  var failed = 0;

  try {
    note('handshake');
    await req('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': const {},
      'clientInfo': {'name': 'verify_p4', 'version': '0'},
    });
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    note('attach');
    final att = await req('tools/call', {
      'name': 'attach',
      'arguments': {
        'vmUri': opts['vm-uri'],
        'platform': opts['platform'],
        'device': opts['device'],
      },
    });
    print1(att);
    if ((att['result'] as Map)['isError'] == true) {
      stderr.writeln('attach failed; aborting');
      failed++;
      return;
    }

    note('get_scene (text)');
    final scene = await req('tools/call', {
      'name': 'get_scene',
      'arguments': const {},
    });
    print1(scene);
    final sceneText = ((scene['result'] as Map)['content'] as List)
        .map((c) => (c as Map)['text'] as String)
        .join('\n');
    if (!sceneText.contains('floating_action_button')) {
      stderr.writeln('scene did not contain floating_action_button — abort');
      failed++;
      return;
    }

    note('tap floating_action_button');
    final tap = await req('tools/call', {
      'name': 'tap',
      'arguments': {'glintId': 'floating_action_button'},
    });
    print1(tap);
    if ((tap['result'] as Map)['isError'] == true) failed++;

    note('get_scene again — counter should advance');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final scene2 = await req('tools/call', {
      'name': 'get_scene',
      'arguments': const {},
    });
    final scene2Text = ((scene2['result'] as Map)['content'] as List)
        .map((c) => (c as Map)['text'] as String)
        .join('\n');
    final counterValue = RegExp(r'"(\d+)"').allMatches(scene2Text).firstOrNull;
    stdout.writeln('counter line: ${counterValue?.group(0)}');

    note('scroll down (direction-based)');
    final scroll = await req('tools/call', {
      'name': 'scroll',
      'arguments': {'direction': 'down', 'amountFraction': 0.5},
    });
    print1(scroll);
    if ((scroll['result'] as Map)['isError'] == true) failed++;

    note('type into text field via focus shortcut');
    final type = await req('tools/call', {
      'name': 'type',
      'arguments': {'text': 'hello p4', 'focus': 'text_field'},
    });
    print1(type);
    if ((type['result'] as Map)['isError'] == true) failed++;

    note('tap unknown glintId → expect errorKind=unresolvedTarget');
    final bad = await req('tools/call', {
      'name': 'tap',
      'arguments': {'glintId': 'does_not_exist'},
    });
    print1(bad);
    final badStructured = (bad['result'] as Map)['structuredContent']
        as Map<String, Object?>;
    if (badStructured['errorKind'] != 'unresolvedTarget') {
      stderr.writeln('expected errorKind=unresolvedTarget; got ${badStructured['errorKind']}');
      failed++;
    }
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0 ? '\nP4 VERIFY: GREEN' : '\nP4 VERIFY: RED ($failed failures)');
  exit(failed == 0 ? 0 : 1);
}
