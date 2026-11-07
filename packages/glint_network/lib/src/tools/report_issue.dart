import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:glint_core/glint_core.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'error_kind.dart';
import 'network_attach.dart';
import 'result.dart';

final reportIssueTool = Tool(
  name: 'report_issue',
  description: 'File an issue in this MCP\'s PUBLIC GitHub repo. type "bug" (wrong '
      'output / crash) or "ux" (awkward / confusing / slow). Only with the '
      'user\'s go-ahead: call with auto:false first to get the drafted issue '
      'without filing, show it to the user, and file only after they approve. '
      'Describe the app generically (e.g. "a banking app\'s PIN screen"); never name '
      'the app, company, bundle id, host or device. Known names, paths and secrets are redacted.',
  inputSchema: Schema.object(
    properties: {
      'type': Schema.string(
        description: '"bug" or "ux". Picks the matching label + template.',
      ),
      'title': Schema.string(
        description: 'One-line summary, naming no app, company, host or device. Redacted before submission.',
      ),
      'body': Schema.string(
        description: 'Issue body (markdown): what broke, what you expected, the '
            'failing tool call; name no app, company, host or device. Redacted before submission.',
      ),
      'auto': Schema.bool(
        description: 'File with gh issue create (default true); false only drafts: it '
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

  final known = knownIdentities();
  final counts = RedactionCounts();
  String redact(String text) => redactForSharing(
        text,
        appNames: known.apps,
        deviceNames: known.devices,
        hosts: known.hosts,
        counts: counts,
      );

  final title = redact(titleRaw);
  final body = redact(bodyRaw);
  final labels = labelsForType(type);
  final redactedNote = counts.describe();
  final redactedSummary = redactedNote == null ? 'redacted nothing' : 'redacted $redactedNote';

  final filed = auto ? await fileWithGh(run: run, title: title, body: body, labels: labels) : null;
  final url = filed?.url;
  if (filed != null && url != null) {
    final dropped = filed.droppedLabels;
    return jsonResult({
      'summary': 'Filed $url ($redactedSummary).',
      'filed': true,
      'method': 'gh-cli',
      'redacted': counts.toJson(),
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
    'summary': 'Drafted, not filed ($redactedSummary).',
    'filed': false,
    'method': 'paste-ready',
    'redacted': counts.toJson(),
    'type': type,
    'labels': labels,
    'title': title,
    'body': body,
    if (saved != null) 'fullBodyPath': saved,
    'url': composeIssueDeepLink(title: title, body: capped, labels: labels),
    'warnings': [
      if (known.hostsUnreadable)
        'the captured host list could not be read, so only hosts written as URLs were redacted; check the draft for hosts',
      if (filed != null && !ghMissing) 'gh issue create ${filed.reason}',
      if (capped.length < body.length)
        'the URL carries the first $kDeepLinkBodyMax chars of the body; the full report is at $saved',
    ],
    'nextSteps': [
      if (!auto)
        'Only names glint knows from this session are redacted; check the draft for any app, company, host or device name',
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

typedef KnownIdentities = ({List<String> apps, List<String> devices, List<String> hosts, bool hostsUnreadable});

/// The app, device and host names this server knows from attached, ended and past sessions, which a public issue must not repeat.
KnownIdentities knownIdentities() {
  final apps = <String>[];
  final devices = <String>[];
  var hostsUnreadable = false;
  final hosts = <String>[];

  void appName(String? name) {
    if (name == null || name.trim().isEmpty) return;
    final parts = dtdAppParts(name);
    if (parts.device == null && parts.package == null) {
      apps.add(name);
      return;
    }
    if (parts.package case final pkg?) apps.add(pkg);
    if (parts.device case final device?) devices.add(device);
  }

  void project(String? path) {
    if (path == null || !io.File('$path${io.Platform.pathSeparator}pubspec.yaml').existsSync()) return;
    apps.addAll(projectIdentityNames(path));
  }

  final registry = SessionRegistry.instance;
  for (final s in registry.attached.values) {
    appName(s.appName);
    project(s.projectPath);
  }
  for (final d in registry.dead) {
    appName(d.appName);
    project(d.projectPath);
  }
  registry.lastLiveApps.values.forEach(appName);

  if (CapturesDatabase.isOpen) {
    try {
      final db = CapturesDao();
      for (final row in db.listSessions(limit: 200)) {
        appName(row['app_name'] as String?);
        project(row['project_path'] as String?);
      }
      hosts.addAll(db.capturedHosts());
    } on Object {
      hostsUnreadable = true;
    }
  }
  return (apps: apps, devices: devices, hosts: hosts, hostsUnreadable: hostsUnreadable);
}
