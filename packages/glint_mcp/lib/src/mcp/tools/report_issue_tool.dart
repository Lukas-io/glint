import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:glint_core/glint_core.dart'
    show capDeepLinkBody, composeIssueDeepLink, fileWithGh, issueLabels, issueRepo, kDeepLinkBodyMax, saveFullIssueBody;

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// Files a bug / UX / feature note into glint's public GitHub repo via the local `gh` CLI, or a pre-filled deep link; everything is path- and secret-redacted first.
class ReportIssueTool extends GlintTool {
  const ReportIssueTool({this.run = Process.run});

  final ProcessRunner run;

  @override
  Tool get definition => Tool(
        name: 'report_issue',
        description:
            'File a glint bug / ux / feature note in the PUBLIC glint GitHub '
            'repo. Only with the user\'s go-ahead: call with dryRun:true '
            'first, show the user the composed issue, and file only after '
            'they approve. includeContext:true (off by default) attaches the '
            'last ~30 action-log entries; typed text is never logged. Uses '
            '`gh issue create` when available, else a pre-filled GitHub URL. '
            'Paths and secrets (tokens, keys, passwords) are redacted.',
        inputSchema: ObjectSchema(
          properties: {
            'type': Schema.string(
              description: 'bug | ux | feature',
            ),
            'title': Schema.string(
              description: 'One-line summary. Redacted before submission.',
            ),
            'body': Schema.string(
              description: 'What happened, what you expected, repro steps. '
                  'Redacted before submission.',
            ),
            'includeContext': Schema.bool(
              description:
                  'Attach the recent action log (tools, targets, outcomes). Default false.',
            ),
            'dryRun': Schema.bool(
              description:
                  'Compose and return the redacted issue without filing. '
                  'Use it to show the user exactly what would be posted.',
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
    final includeContext = argBool(args, 'includeContext') ?? false;
    final dryRun = argBool(args, 'dryRun') ?? false;

    if (!const {'bug', 'ux', 'feature'}.contains(type)) {
      return StructuredResponse.error(
        summary: 'unknown type: $type',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: bug, ux, feature'],
      );
    }

    final title = redactForSharing(titleRaw);
    final fullBody = redactForSharing(
      _composeBody(
        session: session,
        body: bodyRaw,
        includeContext: includeContext,
      ),
    );
    final labels = labelsForType(type);

    if (dryRun) {
      // The summary already carries the composed body readably; don't ship a
      // second raw copy in `pasteBody`. deepLink stays (the fileable form).
      final deepLink = composeIssueDeepLink(
        title: title,
        body: fullBody,
        labels: labels,
      );
      return StructuredResponse(
        summary: 'dry-run — composed body but did not file:\n\n# '
            '$title\n\n$fullBody',
        data: {
          'dryRun': true,
          'type': type,
          'title': title,
          'labels': labels,
          'deepLink': deepLink,
        },
      );
    }

    final filed = await fileWithGh(
      run: run,
      repo: issueRepo,
      title: title,
      body: fullBody,
      labels: labels,
    );
    if (filed.url != null) {
      final dropped = filed.droppedLabels;
      return StructuredResponse(
        summary: 'filed: ${filed.url}'
            '${dropped.isEmpty ? '' : ' (without ${dropped.join(", ")}: not labels of this repo)'}',
        data: {
          'filed': true,
          'method': 'gh-cli',
          'url': filed.url,
          'type': type,
          'title': title,
          'labels': filed.applied,
          if (dropped.isNotEmpty) 'droppedLabels': dropped,
        },
        nextSteps: [
          'mention the URL to the user: ${filed.url}',
          if (dropped.isNotEmpty)
            'maintainer: `gh label create ${dropped.first} --repo $issueRepo` '
                'makes the skipped label(s) stick next time',
        ],
      );
    }

    final saved = saveFullIssueBody(fullBody, prefix: 'glint');
    final capped = capDeepLinkBody(fullBody, savedTo: saved);
    final deepLink = composeIssueDeepLink(
      title: title,
      body: capped,
      labels: filed.applied,
    );
    return StructuredResponse(
      summary: 'gh CLI ${filed.reason}; open this pre-filled URL '
          'instead:\n\n$deepLink',
      data: {
        'filed': false,
        'method': 'paste-ready',
        'type': type,
        'title': title,
        'labels': filed.applied,
        'pasteBody': fullBody,
        if (saved != null) 'fullBodyPath': saved,
        'deepLink': deepLink,
        'repo': issueRepo,
      },
      warnings: [
        filed.reason,
        if (capped.length < fullBody.length)
          'the URL carries the first $kDeepLinkBodyMax chars of the body; '
              'the full report is at $saved',
      ],
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
}

/// Labels for a filed issue: `glint`, the kind, and `agent-filed` so the maintainer can filter MCP-originated reports.
List<String> labelsForType(String type) => issueLabels(package: 'glint', type: type);
