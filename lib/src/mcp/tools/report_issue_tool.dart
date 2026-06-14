import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// File a bug / UX / feature note into glint's GitHub repo via the local
/// `gh` CLI. Falls back to a paste-ready Markdown body if `gh` isn't
/// installed or the user isn't authed.
class ReportIssueTool extends GlintTool {
  const ReportIssueTool();

  static const _repo = 'Lukas-io/glint';

  @override
  Tool get definition => Tool(
        name: 'report_issue',
        description:
            'File a glint bug / ux / feature note. Auto-attaches the last '
            '~30 action-log entries and recent app errors as context. Uses '
            '`gh issue create` when available; falls back to a paste-ready body.',
        inputSchema: ObjectSchema(
          properties: {
            'type': Schema.string(
              description: 'bug | ux | feature',
            ),
            'title': Schema.string(),
            'body': Schema.string(
              description: 'What happened, what you expected, repro steps.',
            ),
            'includeContext': Schema.bool(
              description:
                  'Attach the recent action log + app errors. Default true.',
            ),
            'dryRun': Schema.bool(
              description:
                  'Compose + return the body without actually filing. Useful for previewing.',
            ),
          },
          required: ['type', 'title', 'body'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final type = args['type']! as String;
    final title = args['title']! as String;
    final body = args['body']! as String;
    final includeContext = (args['includeContext'] as bool?) ?? true;
    final dryRun = (args['dryRun'] as bool?) ?? false;

    if (!const {'bug', 'ux', 'feature'}.contains(type)) {
      return StructuredResponse.error(
        summary: 'unknown type: $type',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: bug, ux, feature'],
      );
    }

    final fullBody = _composeBody(
      session: session,
      type: type,
      body: body,
      includeContext: includeContext,
    );

    if (dryRun) {
      return StructuredResponse(
        summary: 'dry-run — composed body but did not file:\n\n# $title\n\n$fullBody',
        data: {
          'pasteBody': fullBody,
          'title': title,
          'type': type,
          'dryRun': true,
        },
      );
    }

    final ghResult = await _tryGh(type: type, title: title, body: fullBody);
    if (ghResult != null) {
      return StructuredResponse(
        summary: 'filed: $ghResult',
        data: {
          'url': ghResult,
          'type': type,
          'title': title,
        },
      );
    }

    return StructuredResponse(
      summary: 'gh CLI not available — paste this into a new issue at '
          'https://github.com/$_repo/issues/new:\n\n# $title\n\n$fullBody',
      data: {
        'pasteBody': fullBody,
        'title': title,
        'type': type,
        'repo': _repo,
      },
      warnings: const [
        'gh CLI unavailable or unauthed; issue not filed automatically'
      ],
    );
  }

  String _composeBody({
    required GlintSession session,
    required String type,
    required String body,
    required bool includeContext,
  }) {
    final buf = StringBuffer()..writeln(body);
    if (!includeContext) return buf.toString();

    final actions = session.actionLog.query(limit: 30).toList();
    if (actions.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('---')
        ..writeln()
        ..writeln('### Recent agent actions')
        ..writeln()
        ..writeln('```')
        ..writeln(const LogRenderer().render(actions))
        ..writeln('```');
    }

    final errors = session.appLogs.query(errorsOnly: true, limit: 10).toList();
    if (errors.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('### Recent app errors')
        ..writeln()
        ..writeln('```');
      for (final e in errors) {
        buf.writeln('[${e.stream.name}] ${e.content}');
      }
      buf.writeln('```');
    }

    return buf.toString();
  }

  Future<String?> _tryGh({
    required String type,
    required String title,
    required String body,
  }) async {
    try {
      final result = await Process.run('gh', [
        'issue', 'create',
        '--repo', _repo,
        '--title', title,
        '--body', body,
        '--label', type,
      ]);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      // gh prints the URL on success.
      return out.isEmpty ? null : out;
    } on Object {
      return null;
    }
  }
}
