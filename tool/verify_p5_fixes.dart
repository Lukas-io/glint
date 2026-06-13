// Live verify for the three gap-fix commits:
//   1. InputEnricher surfaces typed text in get_scene
//   2. ResolveTool returns geometry without side-effecting a tap
//   3. scroll_to_find accepts targetTextContent
//
//   dart run tool/verify_p5_fixes.dart --vm-uri ws://...

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

void main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
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
    proc.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params
    }));
    await proc.stdin.flush();
    return incoming.firstWhere((m) => m['id'] == id);
  }

  void note(String s) => stdout.writeln('\n== $s ==');
  String txtOf(Map<String, Object?> resp) {
    final c = (resp['result'] as Map?)?['content'] as List?;
    return c?.firstOrNull is Map ? (c!.first as Map)['text'] as String : '';
  }

  var failed = 0;

  try {
    note('init');
    await req('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': const {},
      'clientInfo': {'name': 'verify_p5_fixes', 'version': '0'},
    });
    proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    note('attach');
    final att = await req('tools/call', {
      'name': 'attach',
      'arguments': {
        'vmUri': opts['vm-uri'],
        'platform': 'ios',
        'device': opts['device'],
      },
    });
    if ((att['result'] as Map)['isError'] == true) {
      stderr.writeln('attach failed: ${txtOf(att)}');
      failed++;
      return;
    }

    // ── fix 3: scroll_to_find with content predicate.
    note('scroll_to_find targetTextContent="scroll row 27"');
    final find = await req('tools/call', {
      'name': 'scroll_to_find',
      'arguments': {
        'targetTextContent': 'scroll row 27',
        'direction': 'down',
      },
    });
    stdout.writeln(txtOf(find));
    if ((find['result'] as Map)['isError'] == true) {
      stderr.writeln('content-predicate scroll_to_find failed');
      failed++;
    }
    final findStructured =
        (find['result'] as Map)['structuredContent'] as Map<String, Object?>;
    if (findStructured['matchedText'] != 'scroll row 27') {
      stderr.writeln(
          'expected matchedText="scroll row 27"; got ${findStructured['matchedText']}');
      failed++;
    }

    // ── fix 2: resolve tool — geometry without side effect.
    final foundId = findStructured['glintId'] as String;
    note('resolve $foundId (no side effect)');
    final res = await req('tools/call', {
      'name': 'resolve',
      'arguments': {'glintId': foundId},
    });
    stdout.writeln(txtOf(res));
    final resStructured =
        (res['result'] as Map)['structuredContent'] as Map<String, Object?>;
    if (resStructured['physicalCenter'] == null ||
        resStructured['hittable'] != true) {
      stderr.writeln(
          'resolve did not return geometry: ${resStructured.keys.toList()}');
      failed++;
    }

    // ── fix 1: InputEnricher — type, then re-read scene and verify the
    // typed text appears in the input line.
    note('type "ping from p5" into text_field');
    final typeRes = await req('tools/call', {
      'name': 'type',
      'arguments': {'text': 'ping from p5', 'focus': 'text_field'},
    });
    stdout.writeln(txtOf(typeRes));

    await Future<void>.delayed(const Duration(milliseconds: 300));

    note('get_scene → expect "ping from p5" in the input line');
    final scene = await req('tools/call', {
      'name': 'get_scene',
      'arguments': const {},
    });
    final sceneText = txtOf(scene);
    // Surface the input line for the human reader.
    for (final line in sceneText.split('\n')) {
      if (line.contains('input')) stdout.writeln('  $line');
    }
    if (!sceneText.contains('ping from p5')) {
      stderr.writeln(
          'expected "ping from p5" to appear in get_scene after enrichment');
      failed++;
    }
    if (!sceneText.contains('glint type target')) {
      stderr.writeln(
          'expected fixture\'s labelText "glint type target" to appear as the input hint');
      failed++;
    }
  } finally {
    proc.kill();
    await proc.exitCode;
  }

  stdout.writeln(failed == 0
      ? '\nP5 FIXES: GREEN'
      : '\nP5 FIXES: RED ($failed failures)');
  exit(failed == 0 ? 0 : 1);
}
