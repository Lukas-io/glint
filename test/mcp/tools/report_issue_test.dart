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
}
