import 'package:dart_mcp/server.dart';

import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Query the action log. Every tool call is recorded automatically
/// (success or failure) with timestamp + args + summary + elapsedMs.
class LogsTool extends GlintTool {
  const LogsTool();

  @override
  Tool get definition => Tool(
        name: 'logs',
        description:
            'Query the agent action log. Returns the natural-language view by '
            'default; pass `format: json` for the structured entries.',
        inputSchema: ObjectSchema(
          properties: {
            'format': Schema.string(
              description: 'text (default) or json',
            ),
            'limit': Schema.int(
              description: 'Max entries to return. Default 50.',
            ),
            'tool': Schema.string(
              description: 'Filter by tool name (exact match).',
            ),
            'failuresOnly': Schema.bool(),
            'sinceSeq': Schema.int(
              description: 'Return entries with sequence >= sinceSeq.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final format = (args['format'] as String?) ?? 'text';
    final limit = (args['limit'] as int?) ?? 50;
    final toolFilter = args['tool'] as String?;
    final failuresOnly = args['failuresOnly'] as bool?;
    final sinceSeq = args['sinceSeq'] as int?;

    // Note: this tool's own log entry hasn't been recorded yet (logging
    // happens after handle returns), so we won't recursively surface it.
    final entries = session.actionLog
        .query(
          toolFilter: toolFilter,
          failuresOnly: failuresOnly,
          sinceSeq: sinceSeq,
          limit: limit,
        )
        .toList();

    final summary = format == 'json'
        ? _jsonView(entries)
        : const LogRenderer().render(entries);

    return StructuredResponse(
      summary: summary,
      data: {
        'count': entries.length,
        'capacity': session.actionLog.capacity,
        'nextSequence': session.actionLog.nextSequence,
        if (format == 'json')
          'entries': entries.map((e) => e.toJson()).toList(),
      },
    );
  }

  String _jsonView(List<LogEntry> entries) {
    if (entries.isEmpty) return '(empty)';
    return entries.map((e) => e.toJson().toString()).join('\n');
  }
}
