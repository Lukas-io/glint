import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

const String _kRepo = 'Lukas-io/glint';
const String _kIssueNewBase = 'https://github.com/Lukas-io/glint/issues/new';

/// File a bug / UX / feature note into glint's GitHub repo via the local
/// `gh` CLI. Falls back to a pre-filled GitHub deep link when `gh` is
/// missing or fails, so the user always has a one-click filing path.
///
/// Titles, bodies, and the auto-attached context are path-redacted before
/// they leave the machine — `/Users/<name>/...` becomes `<home>/...` or
/// `<project:foo>/...`.
class ReportIssueTool extends GlintTool {
  const ReportIssueTool();

  @override
  Tool get definition => Tool(
        name: 'report_issue',
        description:
            'File a glint bug / ux / feature note. Auto-attaches the last '
            '~30 action-log entries and recent app errors as context. Uses '
            '`gh issue create` when available; falls back to a pre-filled '
            'GitHub deep-link URL. Title + body + context are path-redacted '
            'before submission.',
        inputSchema: ObjectSchema(
          properties: {
            'type': Schema.string(
              description: 'bug | ux | feature',
            ),
            'title': Schema.string(
              description: 'One-line summary. Path-redacted before submission.',
            ),
            'body': Schema.string(
              description:
                  'What happened, what you expected, repro steps. '
                  'Path-redacted before submission.',
            ),
            'includeContext': Schema.bool(
              description:
                  'Attach the recent action log + app errors. Default true.',
            ),
            'dryRun': Schema.bool(
              description:
                  'Compose + return the redacted body without filing. '
                  'Useful for previewing.',
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
    final titleRaw = args['title']! as String;
    final bodyRaw = args['body']! as String;
    final includeContext = (args['includeContext'] as bool?) ?? true;
    final dryRun = (args['dryRun'] as bool?) ?? false;

    if (!const {'bug', 'ux', 'feature'}.contains(type)) {
      return StructuredResponse.error(
        summary: 'unknown type: $type',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: bug, ux, feature'],
      );
    }

    final title = redactPath(titleRaw);
    final fullBody = redactPath(
      _composeBody(
        session: session,
        body: bodyRaw,
        includeContext: includeContext,
      ),
    );
    final labels = labelsForType(type);
    final deepLink = composeIssueDeepLink(
      title: title,
      body: fullBody,
      labels: labels,
    );

    if (dryRun) {
      return StructuredResponse(
        summary: 'dry-run — composed body but did not file:\n\n# '
            '$title\n\n$fullBody',
        data: {
          'dryRun': true,
          'type': type,
          'title': title,
          'labels': labels,
          'pasteBody': fullBody,
          'deepLink': deepLink,
        },
      );
    }

    final ghAttempt = await _tryGh(
      title: title,
      body: fullBody,
      labels: labels,
    );
    if (ghAttempt.url != null) {
      return StructuredResponse(
        summary: 'filed: ${ghAttempt.url}',
        data: {
          'filed': true,
          'method': 'gh-cli',
          'url': ghAttempt.url,
          'type': type,
          'title': title,
          'labels': labels,
        },
        nextSteps: ['mention the URL to the user: ${ghAttempt.url}'],
      );
    }

    return StructuredResponse(
      summary: 'gh CLI ${ghAttempt.reason}; open this pre-filled URL '
          'instead:\n\n$deepLink',
      data: {
        'filed': false,
        'method': 'paste-ready',
        'type': type,
        'title': title,
        'labels': labels,
        'pasteBody': fullBody,
        'deepLink': deepLink,
        'repo': _kRepo,
      },
      warnings: [ghAttempt.reason],
      nextSteps: const [
        'open the deep-link URL — title, body, and labels are pre-filled',
        'install `gh` (https://cli.github.com/) + `gh auth login` for '
            'one-call filing next time',
      ],
    );
  }

  String _composeBody({
    required GlintSession session,
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

    return buf.toString();
  }

  Future<_GhResult> _tryGh({
    required String title,
    required String body,
    required List<String> labels,
  }) async {
    try {
      final result = await Process.run('gh', [
        'issue', 'create',
        '--repo', _kRepo,
        '--title', title,
        '--body', body,
        '--label', labels.join(','),
      ]);
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        return _GhResult(url: out.isEmpty ? null : out);
      }
      final stderr = (result.stderr as String).trim();
      return _GhResult(
        reason: 'exited ${result.exitCode}'
            '${stderr.isEmpty ? '' : ': $stderr'}',
      );
    } on ProcessException catch (e) {
      return _GhResult(reason: 'unavailable (${e.message})');
    } on Object catch (e) {
      return _GhResult(reason: 'failed ($e)');
    }
  }
}

class _GhResult {
  _GhResult({this.url, this.reason = 'unavailable'});
  final String? url;
  final String reason;
}

/// Labels for a filed issue. The `agent-filed` tag lets the maintainer
/// filter MCP-originated reports.
List<String> labelsForType(String type) {
  switch (type) {
    case 'bug':
      return const ['bug', 'agent-filed'];
    case 'ux':
      return const ['ux-friction', 'agent-filed'];
    case 'feature':
      return const ['enhancement', 'agent-filed'];
    default:
      return const ['agent-filed'];
  }
}

/// `https://github.com/.../issues/new?title=…&body=…&labels=…` — the
/// GitHub UI renders the form pre-filled. Used as the fallback when `gh`
/// can't file directly.
String composeIssueDeepLink({
  required String title,
  required String body,
  required List<String> labels,
}) {
  final params = <String, String>{
    'title': title,
    'body': body,
    if (labels.isNotEmpty) 'labels': labels.join(','),
  };
  final query = params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$_kIssueNewBase?$query';
}
