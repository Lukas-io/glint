import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:glint_network/src/tools/report_issue.dart';
import 'package:test/test.dart';

void main() {
  group('labelsForType', () {
    test('bug → [network, bug, agent-filed]', () {
      expect(labelsForType('bug'), ['network', 'bug', 'agent-filed']);
    });

    test('ux → [network, ux-friction, agent-filed]', () {
      expect(labelsForType('ux'), ['network', 'ux-friction', 'agent-filed']);
    });

    test('unknown type → [network, agent-filed]', () {
      expect(labelsForType('weird'), ['network', 'agent-filed']);
    });
  });

  group('reportIssue', () {
    final calls = <List<String>>[];
    setUp(calls.clear);

    Future<Map<String, Object?>> report(Map<String, Object?> args,
        Future<ProcessResult> Function(String, List<String>) run) async {
      final result = await reportIssue(CallToolRequest(name: 'report_issue', arguments: args), run: run);
      final text = result.content.whereType<TextContent>().map((c) => c.text).join();
      return jsonDecode(text) as Map<String, Object?>;
    }

    Future<ProcessResult> gh(String exe, List<String> args) async {
      calls.add(args);
      if (args.first == 'label') return ProcessResult(0, 0, '[{"name":"network"},{"name":"bug"}]', '');
      return ProcessResult(0, 0, 'https://github.com/Lukas-io/glint/issues/1\n', '');
    }

    test('auto:false only drafts, without calling gh', () async {
      final r = await report({'type': 'bug', 'title': 't', 'body': 'b', 'auto': false}, gh);
      expect(r['filed'], isFalse);
      expect(calls, isEmpty);
      expect((r['nextSteps'] as List).first, contains('auto:true'));
    });

    test('files through gh with the labels the repo has', () async {
      final r = await report({'type': 'bug', 'title': 't', 'body': 'b'}, gh);
      expect(r['filed'], isTrue);
      expect(r['labels'], ['network', 'bug']);
      expect(r['droppedLabels'], ['agent-filed']);
    });

    test('without gh it hands back a pre-filled URL and how to install gh', () async {
      final r = await report({'type': 'ux', 'title': 't', 'body': 'b'},
          (exe, args) async => throw const ProcessException('gh', [], 'not found'));
      expect(r['method'], 'paste-ready');
      expect(r['url'], startsWith('https://github.com/Lukas-io/glint/issues/new?'));
      expect(r['warnings'], isEmpty);
      expect((r['nextSteps'] as List).last, contains('Install `gh`'));
    });

    test('a long body is cut in the URL and saved whole', () async {
      final long = 'x' * 7000;
      final r = await report({'type': 'bug', 'title': 't', 'body': long, 'auto': false}, gh);
      final saved = File(r['fullBodyPath']! as String);
      addTearDown(() => saved.deleteSync());
      expect(saved.readAsStringSync(), long);
      expect(Uri.parse(r['url']! as String).queryParameters['body']!.length, lessThan(long.length));
      expect((r['warnings'] as List).single, contains('first 6000 chars'));
    });
  });
}
