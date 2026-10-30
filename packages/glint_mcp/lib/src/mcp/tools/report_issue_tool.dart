import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:glint_core/glint_core.dart'
    show capDeepLinkBody, composeIssueDeepLink, fileWithGh, issueLabels, issueRepo, kDeepLinkBodyMax, saveFullIssueBody;

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../issue_report.dart';
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
        description: 'File a glint bug / ux / feature note in the PUBLIC glint GitHub '
            'repo. Only with the user\'s go-ahead: call with dryRun:true '
            'first, show the user the composed issue, and file only after '
            'they approve. A root-cause-ready report has expected, actual, '
            'timeline, failureSeqs (seq numbers from `logs`, rendered as a '
            'table with the whole error detail), suspectedCause (file or '
            'symbol), suggestedFix, workaround, impact and repro; all '
            'optional, `body` keeps anything else, and dryRun lists what is '
            'missing. An environment block (glint version, host, device, '
            'input setup, mode, other glint process on the device) is always '
            'added. includeContext:true also attaches the last ~30 action-log '
            'entries; typed text is never logged. Uses `gh issue create` when '
            'available, else a pre-filled GitHub URL. Paths and secrets '
            '(tokens, keys, passwords) are redacted.',
        inputSchema: ObjectSchema(
          properties: {
            'type': Schema.string(
              description: 'bug | ux | feature',
            ),
            'title': Schema.string(
              description: 'One-line summary. Redacted before submission.',
            ),
            'body': Schema.string(
              description: 'Anything the fields below do not cover. Redacted before submission.',
            ),
            'expected': Schema.string(description: 'What should have happened.'),
            'actual': Schema.string(description: 'What happened instead: exact reply text, errorKind, numbers.'),
            'timeline': Schema.list(
              items: Schema.string(),
              description: 'Ordered steps with timings, e.g. "t+0 attach ok (2.1s)", "t+4s tap save: notHittable".',
            ),
            'failureSeqs': Schema.list(
              items: Schema.int(),
              description: 'Action-log seq numbers of the failing calls (see `logs`). Rendered as a table of call, '
                  'elapsed time, errorKind and the whole detail.',
            ),
            'suspectedCause': Schema.string(description: 'Where you think it breaks: file, symbol or layer.'),
            'suggestedFix': Schema.string(description: 'What you would change.'),
            'workaround': Schema.string(description: 'What got you unblocked, if anything.'),
            'impact': Schema.string(description: 'Who or what this blocks, and how often.'),
            'repro': Schema.string(description: 'Shortest sequence of calls that shows it.'),
            'includeContext': Schema.bool(
              description: 'Attach the recent action log (tools, targets, outcomes). Default false.',
            ),
            'dryRun': Schema.bool(
              description: 'Compose and return the redacted issue without filing, plus the sections still empty. '
                  'Use it to show the user exactly what would be posted.',
            ),
          },
          required: ['type', 'title'],
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final type = args['type']! as String;
    final titleRaw = args['title']! as String;
    final fields = IssueFields.fromArgs(args);
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
    final sections = renderIssueSections(fields, session.actionLog);
    final fullBody = redactForSharing(
      await _composeBody(
        session: session,
        fields: fields,
        sections: sections.text,
        includeContext: includeContext,
      ),
    );
    final seqWarnings = [
      if (sections.missingSeqs.isNotEmpty)
        'failureSeqs ${sections.missingSeqs.join(', ')} are not in the action log (older than its last '
            '${session.actionLog.capacity} calls, or cleared); the issue says so',
    ];
    final labels = labelsForType(type);

    if (dryRun) {
      // The summary already carries the composed body readably; don't ship a
      // second raw copy in `pasteBody`. deepLink stays (the fileable form).
      final deepLink = composeIssueDeepLink(
        title: title,
        body: fullBody,
        labels: labels,
      );
      final nudges = issueNudges(type, fields, session.actionLog);
      return StructuredResponse(
        summary: 'dry-run — composed body but did not file:\n\n# '
            '$title\n\n$fullBody'
            '${nudges.isEmpty ? '' : '\n\nstill empty (optional):\n${nudges.map((n) => '- $n').join('\n')}'}',
        data: {
          'dryRun': true,
          'type': type,
          'title': title,
          'labels': labels,
          'deepLink': deepLink,
          'missingSections': nudges,
        },
        warnings: seqWarnings,
        nextSteps: [
          if (nudges.isNotEmpty) 'fill what you can from the list above and dry-run again; filing as is also works',
          'show the user the issue above; after they approve, call report_issue again without dryRun',
        ],
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
        warnings: seqWarnings,
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
        ...seqWarnings,
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

  Future<String> _composeBody({
    required GlintSession session,
    required IssueFields fields,
    required String sections,
    required bool includeContext,
  }) async {
    final buf = StringBuffer();
    if (fields.body.isNotEmpty) buf.writeln(fields.body);
    buf.write(sections);

    final actions = includeContext ? session.actionLog.query(limit: 30).toList() : const <LogEntry>[];
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

    if (buf.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('---')
        ..writeln();
    }
    buf
      ..writeln('### Environment')
      ..writeln()
      ..writeln(await renderEnvironment(session, run: run));
    return buf.toString();
  }
}

/// Labels for a filed issue: `glint`, the kind, and `agent-filed` so the maintainer can filter MCP-originated reports.
List<String> labelsForType(String type) => issueLabels(package: 'glint', type: type);
