import 'dart:convert';
import 'dart:io';

/// The public repository every glint package files issues into.
const String issueRepo = 'Lukas-io/glint';

/// Longest body a pre-filled GitHub URL carries; past this the full text is saved to a file.
const int kDeepLinkBodyMax = 6000;

/// Runs one command; injected so tests never shell out to `gh`.
typedef CommandRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Labels for an agent-filed issue: the [package] label, the kind for [type] (`bug`, `ux`, `feature`), and `agent-filed`.
List<String> issueLabels({required String package, required String type}) => [
      package,
      if (_kindLabels[type] case final kind?) kind,
      'agent-filed',
    ];

const _kindLabels = {'bug': 'bug', 'ux': 'ux-friction', 'feature': 'enhancement'};

/// The outcome of a `gh` attempt: a URL and the labels that stuck, or why it failed.
class GhFiling {
  const GhFiling({this.url, this.reason = 'unavailable', this.applied = const [], this.droppedLabels = const []});

  final String? url;
  final String reason;
  final List<String> applied;
  final List<String> droppedLabels;
}

/// Files through `gh`, keeping only labels the repo has and retrying once with none when a label is still refused.
Future<GhFiling> fileWithGh({
  required CommandRunner run,
  required String title,
  required String body,
  required List<String> labels,
  String repo = issueRepo,
}) async {
  try {
    final existing = await existingLabels(run, repo);
    var applied = selectApplicableLabels(labels, existing);
    var result = await _ghIssueCreate(run, repo, title, body, applied);
    if (result.exitCode != 0 && applied.isNotEmpty && isMissingLabelError('${result.stderr}')) {
      applied = const [];
      result = await _ghIssueCreate(run, repo, title, body, applied);
    }
    final dropped = labels.where((l) => !applied.contains(l)).toList();
    if (result.exitCode == 0) {
      final out = '${result.stdout}'.trim();
      return out.isNotEmpty
          ? GhFiling(url: out, applied: applied, droppedLabels: dropped)
          : GhFiling(reason: 'exited 0 without a URL', applied: applied, droppedLabels: dropped);
    }
    final stderr = '${result.stderr}'.trim();
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

Future<ProcessResult> _ghIssueCreate(
        CommandRunner run, String repo, String title, String body, List<String> labels) =>
    run('gh', [
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

/// The repo's label names via `gh label list`; null when the lookup fails, leaving the retry as the safety net.
Future<Set<String>?> existingLabels(CommandRunner run, String repo) async {
  try {
    final r = await run('gh', ['label', 'list', '--repo', repo, '--json', 'name', '-L', '200']);
    if (r.exitCode != 0) return null;
    final decoded = jsonDecode('${r.stdout}');
    if (decoded is! List) return null;
    return decoded.whereType<Map<String, dynamic>>().map((m) => m['name']?.toString()).whereType<String>().toSet();
  } on Object {
    return null;
  }
}

/// Keeps the [desired] labels the repo has; a null [existing] (lookup failed) passes them all through.
List<String> selectApplicableLabels(List<String> desired, Set<String>? existing) =>
    existing == null ? desired : desired.where(existing.contains).toList();

/// True when `gh issue create` refused a label that doesn't exist, so one retry without labels is worth it.
bool isMissingLabelError(String stderr) {
  final s = stderr.toLowerCase();
  return s.contains('not found') && (s.contains('label') || s.contains('could not add'));
}

/// The body that fits a pre-filled URL: cut at [max] with a pointer to [savedTo] when it was longer.
String capDeepLinkBody(String body, {int max = kDeepLinkBodyMax, String? savedTo}) {
  if (body.length <= max) return body;
  return '${body.substring(0, max)}\n\n(cut here; the full report is at ${savedTo ?? 'this machine'})';
}

/// Saves a report too long for a URL to a temp file named after [prefix]; null when the write fails.
String? saveFullIssueBody(String body, {required String prefix}) {
  try {
    final path = '${Directory.systemTemp.path}/$prefix-issue-${DateTime.now().millisecondsSinceEpoch}.md';
    File(path).writeAsStringSync(body);
    return path;
  } on Object {
    return null;
  }
}

/// The GitHub new-issue URL with title, body and labels pre-filled; the fallback when `gh` can't file.
String composeIssueDeepLink({
  required String title,
  required String body,
  required List<String> labels,
  String repo = issueRepo,
}) {
  final params = <String, String>{
    'title': title,
    'body': body,
    if (labels.isNotEmpty) 'labels': labels.join(','),
  };
  final query = params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return 'https://github.com/$repo/issues/new?$query';
}
