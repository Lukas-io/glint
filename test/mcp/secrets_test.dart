import 'package:dart_mcp/server.dart';
import 'package:glint/glint.dart';
import 'package:test/test.dart';

Map<String, Object?> _structured(CallToolResult r) => r.structuredContent!;

void main() {
  test('the action log keeps the length of typed text, never the text',
      () async {
    final session = GlintSession();
    await const TypeTool().invoke(
      session,
      CallToolRequest(name: 'type', arguments: const {'text': 'hunter2!!'}),
    );
    final entry = session.actionLog.query(limit: 1).single;
    final args = switch (entry) {
      SuccessEntry() => entry.args,
      FailureEntry() => entry.args,
    };
    expect(args?['text'], '<9 chars>');
    expect(const TypeText('hunter2!!').label, 'type 9 chars');
    expect(const LogRenderer().render([entry]), isNot(contains('hunter2')));
  });

  test('report_issue attaches no context by default and redacts secrets',
      () async {
    final session = GlintSession();
    await const TypeTool().invoke(
      session,
      CallToolRequest(name: 'type', arguments: const {'text': 'hunter2!!'}),
    );
    final result = await const ReportIssueTool().invoke(
      session,
      CallToolRequest(name: 'report_issue', arguments: const {
        'type': 'bug',
        'title': 'login fails with password=hunter2',
        'body':
            'Authorization: Bearer abcdef1234567890 at /Users/someone/code/app/lib/main.dart',
        'dryRun': true,
      }),
    );
    final summary = _structured(result)['summary']! as String;
    expect(summary, isNot(contains('hunter2')));
    expect(summary, isNot(contains('abcdef1234567890')));
    expect(summary, isNot(contains('someone')));
    expect(summary, isNot(contains('Recent agent actions')));
  });
}
