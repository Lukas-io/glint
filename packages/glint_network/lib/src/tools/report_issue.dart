import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:glint_core/glint_core.dart';

import 'error_kind.dart';
import 'result.dart';

final reportIssueTool = Tool(
  name: 'report_issue',
  description:
      'File an issue in this MCP\'s PUBLIC GitHub repo. type "bug" (wrong '
      'output / crash) or "ux" (awkward / confusing / slow). Only with the '
      'user\'s go-ahead: call with auto:false first to get the drafted issue '
      'without filing, show it to the user, and file only after they approve. '
      'Paths and secrets (tokens, keys, passwords) are redacted.',
  inputSchema: Schema.object(
    properties: {
      'type': Schema.string(
        description: '"bug" or "ux". Picks the matching label + template.',
      ),
      'title': Schema.string(
        description: 'One-line summary. Redacted before submission.',
      ),
      'body': Schema.string(
        description:
            'Issue body (markdown): what broke, what you expected, the '
            'failing tool call. Redacted before submission.',
      ),
      'auto': Schema.bool(
        description:
            'File with gh issue create (default true); false only drafts: it '
            'returns the redacted issue and a paste-ready URL, filing nothing.',
      ),
    },
    required: ['type', 'title', 'body'],
  ),
);

FutureOr<CallToolResult> reportIssue(CallToolRequest request, {CommandRunner run = io.Process.run}) async {
  final args = request.arguments ?? const <String, Object?>{};
  final type = args['type'] as String?;
  final titleRaw = args['title'] as String?;
  final bodyRaw = args['body'] as String?;
  final auto = (args['auto'] as bool?) ?? true;

  if (type == null || (type != 'bug' && type != 'ux')) {
    return errorResult(
      'report_issue: `type` must be "bug" or "ux", got "$type".',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': ['Retry with type:"bug" or type:"ux"'],
      },
    );
  }
  if (titleRaw == null || titleRaw.isEmpty) {
    return errorResult('report_issue: `title` is required.', kind: ErrorKind.badArgument);
  }
  if (bodyRaw == null || bodyRaw.isEmpty) {
    return errorResult('report_issue: `body` is required.', kind: ErrorKind.badArgument);
  }

  final title = redactForSharing(titleRaw);
  final body = redactForSharing(bodyRaw);
  final labels = labelsForType(type);

  final filed = auto ? await fileWithGh(run: run, title: title, body: body, labels: labels) : null;
  final url = filed?.url;
  if (filed != null && url != null) {
    final dropped = filed.droppedLabels;
    return jsonResult({
      'filed': true,
      'method': 'gh-cli',
      'type': type,
      'labels': filed.applied,
      if (dropped.isNotEmpty) 'droppedLabels': dropped,
      'title': title,
      'url': url,
      'nextSteps': [
        'Mention the URL to the user: $url',
        if (dropped.isNotEmpty)
          'Skipped label(s) not present in the repo so they could not block filing: ${dropped.join(", ")}',
        'Optionally save a session_note linking to the issue for future continuity',
      ],
    });
  }

  final ghMissing = filed == null || filed.reason.startsWith('unavailable');
  final saved = body.length > kDeepLinkBodyMax ? saveFullIssueBody(body, prefix: 'glint_network') : null;
  final capped = capDeepLinkBody(body, savedTo: saved);
  return jsonResult({
    'filed': false,
    'method': 'paste-ready',
    'type': type,
    'labels': labels,
    'title': title,
    'body': body,
    if (saved != null) 'fullBodyPath': saved,
    'url': composeIssueDeepLink(title: title, body: capped, labels: labels),
    'warnings': [
      if (filed != null && !ghMissing) 'gh issue create ${filed.reason}',
      if (capped.length < body.length)
        'the URL carries the first $kDeepLinkBodyMax chars of the body; the full report is at $saved',
    ],
    'nextSteps': [
      if (!auto) 'Show the user the drafted issue; with their go-ahead, call again with auto:true',
      'Open the deep-link URL above; the title, body and labels are pre-filled',
      if (auto && ghMissing)
        'Install `gh` (https://cli.github.com/) and run `gh auth login` for one-call filing next time'
      else if (auto)
        'If `gh auth status` shows you are logged out, run `gh auth login` and retry',
    ],
  });
}

/// Labels for a filed issue: `network`, the kind, and `agent-filed`.
List<String> labelsForType(String type) => issueLabels(package: 'network', type: type);
