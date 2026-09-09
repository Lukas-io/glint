import 'dart:io';

import 'package:glint/interaction.dart' show ProcessRunner;
import 'package:glint/src/mcp/tools/report_issue_tool.dart';
import 'package:test/test.dart';

void main() {
  group('labelsForType', () {
    test('bug → [bug, agent-filed]', () {
      expect(labelsForType('bug'), ['bug', 'agent-filed']);
    });

    test('ux → [ux-friction, agent-filed]', () {
      expect(labelsForType('ux'), ['ux-friction', 'agent-filed']);
    });

    test('feature → [enhancement, agent-filed]', () {
      expect(labelsForType('feature'), ['enhancement', 'agent-filed']);
    });

    test('unknown type → [agent-filed]', () {
      expect(labelsForType('weird'), ['agent-filed']);
    });
  });

  group('composeIssueDeepLink', () {
    test('basic title + body + labels url-encoded into query params', () {
      final url = composeIssueDeepLink(
        title: 'tap missed the target',
        body: 'expected hit on submit_button',
        labels: ['bug', 'agent-filed'],
      );
      expect(url, startsWith('https://github.com/Lukas-io/glint/issues/new?'));
      expect(url, contains('title=tap+missed+the+target'));
      expect(url, contains('body=expected+hit+on+submit_button'));
      expect(url, contains('labels=bug%2Cagent-filed'));
    });

    test('special characters encoded safely', () {
      final url = composeIssueDeepLink(
        title: 'scroll & wait: failed',
        body: '```dart\nthrow Error("oops");\n```',
        labels: ['bug'],
      );
      expect(url, contains('scroll+%26+wait'));
      expect(url, contains('%3A'), reason: ': must be percent-encoded');
      expect(url, contains('%60%60%60'),
          reason: 'triple backtick must be percent-encoded');
      expect(url, contains('throw+Error%28%22oops%22%29%3B'));
    });

    test('empty labels list omits labels param', () {
      final url = composeIssueDeepLink(title: 't', body: 'b', labels: []);
      expect(url, isNot(contains('labels=')));
      expect(url, contains('title=t'));
    });

    test('newlines in body encoded as %0A', () {
      final url = composeIssueDeepLink(
        title: 't',
        body: 'line 1\nline 2',
        labels: [],
      );
      expect(url, contains('%0A'));
    });
  });

  group('selectApplicableLabels', () {
    test('keeps only labels the repo has', () {
      expect(selectApplicableLabels(['bug', 'agent-filed'], {'bug', 'question'}),
          ['bug']);
    });

    test('a failed lookup passes every label through', () {
      expect(selectApplicableLabels(['bug', 'agent-filed'], null),
          ['bug', 'agent-filed']);
    });

    test('nothing matches, nothing applied', () {
      expect(selectApplicableLabels(['ux-friction'], {'bug'}), isEmpty);
    });
  });

  group('isMissingLabelError', () {
    test('matches the real gh wording', () {
      expect(
          isMissingLabelError(
              "could not add label: 'agent-filed' not found"),
          isTrue);
    });

    test('ignores unrelated failures', () {
      expect(isMissingLabelError('authentication required'), isFalse);
      expect(isMissingLabelError('repository not found'), isFalse);
    });
  });

  group('capDeepLinkBody', () {
    test('short bodies pass through', () {
      expect(capDeepLinkBody('hello', max: 10), 'hello');
    });

    test('long bodies are cut and point at the saved file', () {
      final out = capDeepLinkBody('x' * 30, max: 10, savedTo: '/tmp/full.md');
      expect(out, startsWith('x' * 10));
      expect(out, isNot(contains('x' * 11)));
      expect(out, contains('/tmp/full.md'));
    });
  });

  group('fileWithGh', () {
    ProcessRunner script(List<ProcessResult> replies, List<List<String>> calls) {
      var i = 0;
      return (exe, args) async {
        calls.add([exe, ...args]);
        if (i >= replies.length) throw StateError('no reply scripted for $args');
        return replies[i++];
      };
    }

    ProcessResult r(int code, {String out = '', String err = ''}) =>
        ProcessResult(0, code, out, err);

    test('labels the repo lacks are dropped before the create', () async {
      final calls = <List<String>>[];
      final run = script([
        r(0, out: '[{"name":"bug"},{"name":"question"}]'),
        r(0, out: 'https://github.com/o/r/issues/7\n'),
      ], calls);
      final f = await fileWithGh(
          run: run, repo: 'o/r', title: 't', body: 'b', labels: ['bug', 'agent-filed']);
      expect(f.url, 'https://github.com/o/r/issues/7');
      expect(f.applied, ['bug']);
      expect(f.droppedLabels, ['agent-filed']);
      expect(calls[1], contains('--label'));
      expect(calls[1][calls[1].indexOf('--label') + 1], 'bug');
    });

    test('a refused label is retried once with no labels at all', () async {
      final calls = <List<String>>[];
      final run = script([
        r(1, err: 'gh: offline'),
        r(1, err: "could not add label: 'agent-filed' not found"),
        r(0, out: 'https://github.com/o/r/issues/8'),
      ], calls);
      final f = await fileWithGh(
          run: run, repo: 'o/r', title: 't', body: 'b', labels: ['ux-friction', 'agent-filed']);
      expect(f.url, 'https://github.com/o/r/issues/8');
      expect(f.applied, isEmpty);
      expect(f.droppedLabels, ['ux-friction', 'agent-filed']);
      expect(calls.length, 3);
      expect(calls[2], isNot(contains('--label')));
    });

    test('other failures are reported, not retried', () async {
      final calls = <List<String>>[];
      final run = script([
        r(0, out: '[]'),
        r(1, err: 'authentication required'),
      ], calls);
      final f = await fileWithGh(
          run: run, repo: 'o/r', title: 't', body: 'b', labels: ['bug']);
      expect(f.url, isNull);
      expect(f.reason, contains('authentication required'));
      expect(calls.length, 2);
    });

    test('a missing gh binary reads as unavailable', () async {
      final f = await fileWithGh(
        run: (exe, args) async => throw const ProcessException('gh', [], 'not found', 2),
        repo: 'o/r', title: 't', body: 'b', labels: ['bug'],
      );
      expect(f.url, isNull);
      expect(f.reason, startsWith('unavailable'));
    });
  });
}
