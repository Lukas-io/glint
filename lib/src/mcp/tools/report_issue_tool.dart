import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

const String _kRepo = 'Lukas-io/glint';
const String _kIssueNewBase = 'https://github.com/Lukas-io/glint/issues/new';

/// Longest body the pre-filled GitHub URL carries; the full text is saved to a file past this.
const int kDeepLinkBodyMax = 6000;

/// File a bug / UX / feature note into glint's GitHub repo via the local `gh`
/// CLI, falling back to a pre-filled GitHub deep link when `gh` is missing or
/// fails. Titles, bodies, and auto-attached context are path-redacted before
/// they leave the machine (`/Users/<name>/...` → `<home>/...` or `<project:foo>/...`).
class ReportIssueTool extends GlintTool {
  const ReportIssueTool({this.run = Process.run});

  final ProcessRunner run;

  @override
  Tool get definition => Tool(
        name: 'report_issue',
        description:
            'File a glint bug / ux / feature note. Auto-attaches the last '
            '~30 action-log entries and recent app errors as context. Uses '
            '`gh issue create` when available (labels the repo lacks are '
            'skipped, never a reason not to file); falls back to a pre-filled '
            'GitHub deep-link URL with the full body saved to a file. Title + '
            'body + context are path-redacted before submission.',
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
      repo: _kRepo,
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
            'maintainer: `gh label create ${dropped.first} --repo $_kRepo` '
                'makes the skipped label(s) stick next time',
        ],
      );
    }

    final saved = _saveFullBody(fullBody);
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
        'repo': _kRepo,
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

  /// Writes the whole body next to the other glint temp files; null when the write fails.
  String? _saveFullBody(String body) {
    try {
      final path =
          '${Directory.systemTemp.path}/glint-issue-${DateTime.now().millisecondsSinceEpoch}.md';
      File(path).writeAsStringSync(body);
      return path;
    } on Object {
      return null;
    }
  }
}

/// Outcome of the `gh` attempt: a URL with the labels that stuck, or the reason it failed.
class GhFiling {
  const GhFiling({
    this.url,
    this.reason = 'unavailable',
    this.applied = const [],
    this.droppedLabels = const [],
  });

  final String? url;
  final String reason;
  final List<String> applied;
  final List<String> droppedLabels;
}

/// Files through `gh`, keeping only labels the repo has and retrying once with none when a label is still refused.
Future<GhFiling> fileWithGh({
  required ProcessRunner run,
  required String repo,
  required String title,
  required String body,
  required List<String> labels,
}) async {
  try {
    final existing = await existingLabels(run, repo);
    var applied = selectApplicableLabels(labels, existing);
    var result = await _ghIssueCreate(run, repo, title, body, applied);
    if (result.exitCode != 0 &&
        applied.isNotEmpty &&
        isMissingLabelError((result.stderr as String?) ?? '')) {
      applied = const [];
      result = await _ghIssueCreate(run, repo, title, body, applied);
    }
    final dropped = labels.where((l) => !applied.contains(l)).toList();
    if (result.exitCode == 0) {
      final out = ((result.stdout as String?) ?? '').trim();
      if (out.isNotEmpty) {
        return GhFiling(url: out, applied: applied, droppedLabels: dropped);
      }
      return GhFiling(
          reason: 'exited 0 without a URL', applied: applied, droppedLabels: dropped);
    }
    final stderr = ((result.stderr as String?) ?? '').trim();
    return GhFiling(
      reason: 'exited ${result.exitCode}${stderr.isEmpty ? '' : ': $stderr'}',
      applied: applied,
      droppedLabels: dropped,
    );
  } on ProcessException catch (e) {
    return GhFiling(reason: 'unavailable (${e.message})');
  } on Object catch (e) {
    return GhFiling(reason: 'failed ($e)');
  }
}

Future<ProcessResult> _ghIssueCreate(ProcessRunner run, String repo,
    String title, String body, List<String> labels) {
  return run('gh', [
    'issue',
    'create',
    '--repo',
    repo,
    '--title',
    title,
    '--body',
    body,
    if (labels.isNotEmpty) ...['--label', labels.join(',')],
  ]);
}

/// The repo's label names via `gh label list`; null when the lookup fails, so the caller keeps its retry as the safety net.
Future<Set<String>?> existingLabels(ProcessRunner run, String repo) async {
  try {
    final r = await run('gh',
        ['label', 'list', '--repo', repo, '--json', 'name', '-L', '200']);
    if (r.exitCode != 0) return null;
    final decoded = jsonDecode((r.stdout as String?) ?? '');
    if (decoded is! List) return null;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((m) => m['name']?.toString())
        .whereType<String>()
        .toSet();
  } on Object {
    return null;
  }
}

/// Keeps the [desired] labels the repo has; a null [existing] (lookup failed) passes them all through.
List<String> selectApplicableLabels(
    List<String> desired, Set<String>? existing) {
  if (existing == null) return desired;
  return desired.where(existing.contains).toList();
}

/// True when `gh issue create` refused a label that does not exist, so a retry without labels is worth one try.
bool isMissingLabelError(String stderr) {
  final s = stderr.toLowerCase();
  return s.contains('not found') &&
      (s.contains('label') || s.contains('could not add'));
}

/// The body that fits a pre-filled URL: cut at [max] with a pointer to [savedTo] when it was longer.
String capDeepLinkBody(String body,
    {int max = kDeepLinkBodyMax, String? savedTo}) {
  if (body.length <= max) return body;
  return '${body.substring(0, max)}\n\n(cut here; the full report is at ${savedTo ?? 'this machine'})';
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
