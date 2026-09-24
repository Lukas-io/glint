import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

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
            'errorsOnly': Schema.bool(
              description: 'Only entries that look like exceptions / stack '
                  'traces.',
            ),
            'format': Schema.string(
              description: 'text (default, rendered) or json (structured '
                  'entries — pass this to get the entries array).',
            ),
            'stream': Schema.string(
              description: 'Filter: stderr or logging.',
            ),
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
    final limit = argInt(args, 'limit') ?? 50;
    final errorsOnly = argBool(args, 'errorsOnly') ?? false;
    final asJson = (args['format'] as String?) == 'json';
    final streamName = args['stream'] as String?;
    final sinceSeq = argInt(args, 'sinceSeq');

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
        ? '(no entries)${_whyEmpty(session)}'
        : entries.map(_renderEntry).join('\n');

    return StructuredResponse(
      summary: summary,
      nextSteps: entries.isEmpty ? _emptyNextSteps(session) : const [],
      data: {
        'count': entries.length,
        'capacity': session.appLogs.capacity,
        'nextSequence': session.appLogs.nextSequence,
        // The rendered summary already carries the entries; only ship the
        // structured array when json is explicitly requested (matches `logs`).
        if (asJson) 'entries': entries.map((e) => e.toJson()).toList(),
      },
    );
  }

  /// Logs come from the VM connection, which device mode and an unattached session do not have.
  String _whyEmpty(GlintSession session) {
    final active = session.active;
    if (active == null) return ': not attached, so no app logs are collected';
    if (active.deviceMode) {
      return ': device mode has no VM connection, so app logs are not collected';
    }
    return '';
  }

  List<String> _emptyNextSteps(GlintSession session) {
    final active = session.active;
    if (active == null) return const ['attach (no args) to start collecting app logs'];
    if (!active.deviceMode) return const [];
    return const [
      'once the Flutter app runs in debug mode, attach without mode:"device" to collect its logs',
      'until then read logs where the app was launched (the flutter run output)',
    ];
  }

  String _renderEntry(AppLogEntry e) {
    final tag = e.loggerName != null ? '${e.stream.name}:${e.loggerName}'
        : e.stream.name;
    return '[seq=${e.sequence} ${e.timestamp.toIso8601String()} $tag] ${e.content}';
  }
}
