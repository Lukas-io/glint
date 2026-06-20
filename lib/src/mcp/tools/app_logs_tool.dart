import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Query the app-side log buffer — FlutterError exceptions, developer.log
/// messages, anything the running Flutter app wrote to stderr or logging.
/// Distinct from the `logs` tool which records glint's own tool calls.
class AppLogsTool extends GlintTool {
  const AppLogsTool();

  @override
  Tool get definition => Tool(
        name: 'app_logs',
        description:
            'Query the running app\'s log buffer (FlutterError dumps + '
            'developer.log + stderr writes). Use `errorsOnly` to surface only '
            'entries that look like exceptions / stack traces.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': Schema.int(description: 'Max entries. Default 50.'),
            'errorsOnly': Schema.bool(),
            'stream': Schema.string(
              description: 'Filter: stderr or logging.',
            ),
            'sinceSeq': Schema.int(),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final limit = (args['limit'] as int?) ?? 50;
    final errorsOnly = (args['errorsOnly'] as bool?) ?? false;
    final streamName = args['stream'] as String?;
    final sinceSeq = args['sinceSeq'] as int?;

    AppLogStream? streamFilter;
    if (streamName != null) {
      streamFilter = AppLogStream.values
          .where((s) => s.name == streamName)
          .firstOrNull;
      if (streamFilter == null) {
        return StructuredResponse.error(
          summary: 'unknown stream: $streamName',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use stderr or logging'],
        );
      }
    }

    final entries = session.appLogs
        .query(
          limit: limit,
          errorsOnly: errorsOnly,
          streamFilter: streamFilter,
          sinceSeq: sinceSeq,
        )
        .toList();

    final summary = entries.isEmpty
        ? '(no entries)'
        : entries.map(_renderEntry).join('\n');

    return StructuredResponse(
      summary: summary,
      data: {
        'count': entries.length,
        'capacity': session.appLogs.capacity,
        'nextSequence': session.appLogs.nextSequence,
        'entries': entries.map((e) => e.toJson()).toList(),
      },
    );
  }

  String _renderEntry(AppLogEntry e) {
    final tag = e.loggerName != null ? '${e.stream.name}:${e.loggerName}'
        : e.stream.name;
    return '[seq=${e.sequence} ${e.timestamp.toIso8601String()} $tag] ${e.content}';
  }
}
