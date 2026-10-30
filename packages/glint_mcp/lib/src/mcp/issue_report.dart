import 'dart:async';
import 'dart:io';

import '../../interaction.dart';
import '../../observability.dart';
import '../version.dart';
import 'session.dart';
import 'tool_args.dart';

/// The structured parts of a `report_issue` call; every field is optional.
class IssueFields {
  const IssueFields({
    this.body = '',
    this.expected,
    this.actual,
    this.timeline = const [],
    this.failureSeqs = const [],
    this.suspectedCause,
    this.suggestedFix,
    this.workaround,
    this.impact,
    this.repro,
  });

  factory IssueFields.fromArgs(Map<String, Object?> args) => IssueFields(
        body: _text(args['body']) ?? '',
        expected: _text(args['expected']),
        actual: _text(args['actual']),
        timeline: _strings(args, 'timeline'),
        failureSeqs: _seqs(args),
        suspectedCause: _text(args['suspectedCause']),
        suggestedFix: _text(args['suggestedFix']),
        workaround: _text(args['workaround']),
        impact: _text(args['impact']),
        repro: _text(args['repro']),
      );

  final String body;
  final String? expected;
  final String? actual;
  final List<String> timeline;
  final List<int> failureSeqs;
  final String? suspectedCause;
  final String? suggestedFix;
  final String? workaround;
  final String? impact;
  final String? repro;

  static String? _text(Object? raw) {
    final s = raw is String ? raw.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  static List<String> _strings(Map<String, Object?> args, String key) {
    final raw = args[key];
    if (raw == null) return const [];
    if (raw is! List) throw ArgTypeError(key, 'a list of strings', raw);
    return [
      for (final e in raw)
        if (_text(e is String ? e : '$e') case final s?) s,
    ];
  }

  static List<int> _seqs(Map<String, Object?> args) {
    final raw = args['failureSeqs'];
    if (raw == null) return const [];
    if (raw is! List) throw ArgTypeError('failureSeqs', 'a list of action-log seq numbers', raw);
    final seqs = <int>{};
    for (final e in raw) {
      final n = looseInt(e);
      if (n == null) throw ArgTypeError('failureSeqs', 'a list of action-log seq numbers', raw);
      seqs.add(n);
    }
    return seqs.toList()..sort();
  }
}

/// The composed issue and the seqs that were asked for but are no longer in the action log.
typedef IssueSections = ({String text, List<int> missingSeqs});

/// Renders [fields] as markdown sections in a fixed order: expected, actual, timeline, failures, suspected cause, suggested fix, workaround, impact, repro.
IssueSections renderIssueSections(IssueFields fields, ActionLog log) {
  final buf = StringBuffer();
  void section(String heading, String? text) {
    if (text == null) return;
    buf
      ..writeln()
      ..writeln('### $heading')
      ..writeln()
      ..writeln(text);
  }

  section('Expected', fields.expected);
  section('Actual', fields.actual);
  section('Timeline', fields.timeline.isEmpty ? null : _numbered(fields.timeline));
  final failures = renderFailureTable(fields.failureSeqs, log);
  section('Failures from the action log', failures.text.isEmpty ? null : failures.text);
  section('Suspected cause', fields.suspectedCause);
  section('Suggested fix', fields.suggestedFix);
  section('Workaround', fields.workaround);
  section('Impact', fields.impact);
  section('Repro', fields.repro);
  return (text: buf.toString(), missingSeqs: failures.missingSeqs);
}

String _numbered(List<String> items) => [
      for (var i = 0; i < items.length; i++) '${i + 1}. ${items[i]}',
    ].join('\n');

/// A table of the action-log entries [seqs] name (`seq | time | call | elapsed | errorKind | detail`), with every multi-line detail printed whole under it.
IssueSections renderFailureTable(List<int> seqs, ActionLog log) {
  if (seqs.isEmpty) return (text: '', missingSeqs: const []);
  final bySeq = {for (final e in log.query(limit: log.capacity)) e.sequence: e};
  final found = [
    for (final s in seqs)
      if (bySeq[s] case final e?) e,
  ];
  final missing = [
    for (final s in seqs)
      if (!bySeq.containsKey(s)) s,
  ];
  final buf = StringBuffer();
  if (found.isNotEmpty) {
    buf
      ..writeln('| seq | time | call | elapsed | errorKind | detail |')
      ..writeln('|---|---|---|---|---|---|');
    for (final e in found) {
      final detail = _entryDetail(e);
      final lines = detail.split('\n');
      final cell = lines.length == 1 ? detail : '${lines.first} (full text below)';
      buf.writeln('| ${e.sequence} | ${_clock(e.timestamp)} | ${_callCell(e)} | ${e.elapsedMs}ms | '
          '${_kind(e)} | ${_cell(cell)} |');
    }
    for (final e in found) {
      final detail = _entryDetail(e);
      if (!detail.contains('\n')) continue;
      buf
        ..writeln()
        ..writeln('seq ${e.sequence} detail:')
        ..writeln()
        ..writeln(_fenced(detail));
    }
  }
  if (missing.isNotEmpty) {
    if (found.isNotEmpty) buf.writeln();
    buf.writeln(
        'Not in the action log (older than its last ${log.capacity} calls, or cleared): ${missing.join(', ')}.');
  }
  return (text: buf.toString().trimRight(), missingSeqs: missing);
}

String _kind(LogEntry e) => switch (e) {
      FailureEntry() => e.errorKind.name,
      SuccessEntry() => 'ok',
    };

/// The reason a call failed, whole; a success has only its summary.
String _entryDetail(LogEntry e) => switch (e) {
      FailureEntry() => (e.detail != null && e.detail!.trim().isNotEmpty) ? e.detail!.trimRight() : e.summary,
      SuccessEntry() => e.summary,
    };

String _clock(DateTime t) => t.toIso8601String().substring(11, 23);

String _callCell(LogEntry e) {
  final args = switch (e) {
    FailureEntry() => e.args,
    SuccessEntry() => e.args,
  };
  final call = args == null || args.isEmpty ? e.tool : '${e.tool} ${_compactJson(args)}';
  return '`${_cell(call.replaceAll('`', "'"))}`';
}

String _compactJson(Map<String, Object?> args) => [
      for (final e in args.entries) '${e.key}=${e.value}',
    ].join(' ');

String _cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');

String _fenced(String text) {
  final longest = RegExp('`+').allMatches(text).fold<int>(0, (m, x) => x.group(0)!.length > m ? x.group(0)!.length : m);
  final fence = '`' * (longest < 3 ? 3 : longest + 1);
  return '$fence\n$text\n$fence';
}

/// The most recent failures in [log], newest last, as `seq N tool errorKind` lines.
List<String> recentFailureHints(ActionLog log, {int limit = 5}) => [
      for (final e in log.query(failuresOnly: true, limit: limit)) 'seq ${e.sequence} ${e.tool} ${_kind(e)}',
    ];

/// What a draft is missing, so the agent can fill it before filing; never a reason to refuse.
List<String> issueNudges(String type, IssueFields f, ActionLog log) {
  final nudges = <String>[];
  void missing(Object? value, String message) {
    final empty = value == null || (value is List && value.isEmpty);
    if (empty) nudges.add(message);
  }

  if (type == 'feature') {
    missing(f.impact, 'no impact: who needs this, and what they do today instead');
    return nudges;
  }
  missing(f.expected, 'no expected: say what the call or screen should have done');
  missing(f.actual, 'no actual: say what happened, with the exact reply text or error');
  if (type == 'bug') {
    missing(f.timeline, 'no timeline: list the steps and timings (what you called, in order, and when it went wrong)');
    if (f.failureSeqs.isEmpty) {
      final hints = recentFailureHints(log);
      nudges.add('no failure seqs attached: pass the action-log seqs of the failing calls as failureSeqs'
          '${hints.isEmpty ? ' (the action log holds no failures)' : ' (recent failures: ${hints.join('; ')})'}');
    }
    missing(f.suspectedCause, 'no suspected cause: name the file, symbol or layer you think is at fault, if you can');
  }
  missing(f.repro, 'no repro: the shortest sequence of calls that shows it');
  return nudges;
}

/// The environment block appended to every issue: glint, host, device, input setup, mode and any other glint process on the device.
Future<String> renderEnvironment(GlintSession session, {ProcessRunner run = Process.run}) async {
  final lines = <String>[];
  final commit = await glintCommit(run: run);
  lines.add('- glint: $glintVersion${commit == null ? '' : ' (commit $commit)'}');

  final app = session.active;
  final xcode = app?.device is IosSimulator ? (app!.device as IosSimulator).toolchain?.xcode.version : null;
  lines.add('- host: ${await _hostLine(run)}${xcode == null ? '' : ', Xcode $xcode'}');

  if (app == null) {
    lines.add('- device: not attached');
    return lines.join('\n');
  }
  lines
    ..add('- mode: ${app.deviceMode ? 'device (no Flutter app)' : 'flutter'}')
    ..add('- device: ${app.deviceName ?? app.device.id} (${app.device.platform.name}, ${app.device.id})')
    ..add('- input: ${app.inputSetup ?? 'setup not recorded for this attach'} · route ${app.device.route.name}');
  if (!app.deviceMode) lines.add('- app: ${app.label}');
  if (DeviceClaims().heldByOther(app.device.id) case final claim?) {
    lines.add('- another glint process holds this device: ${claim.describe}');
  }
  return lines.join('\n');
}

Future<String> _hostLine(ProcessRunner run) async {
  if (!Platform.isMacOS) return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  try {
    final r = await run('sw_vers', ['-productVersion']).timeout(const Duration(seconds: 3));
    final v = '${r.stdout}'.trim();
    if (r.exitCode == 0 && v.isNotEmpty) return 'macOS $v';
  } on Object {
    // an unreadable macOS version only drops the number
  }
  return 'macOS';
}

String? _commit;
bool _commitRead = false;

/// Short git commit this glint runs from when it runs from a checkout of the glint repo; null for an installed package.
Future<String?> glintCommit({ProcessRunner run = Process.run}) async {
  if (_commitRead) return _commit;
  _commitRead = true;
  try {
    final dir = File(Platform.script.toFilePath()).parent.path;
    final top = await run('git', ['-C', dir, 'rev-parse', '--show-toplevel']).timeout(const Duration(seconds: 3));
    if (top.exitCode != 0) return null;
    final root = '${top.stdout}'.trim();
    if (!File('$root/packages/glint_mcp/pubspec.yaml').existsSync()) return null;
    final head = await run('git', ['-C', root, 'rev-parse', '--short', 'HEAD']).timeout(const Duration(seconds: 3));
    final sha = '${head.stdout}'.trim();
    if (head.exitCode == 0 && sha.isNotEmpty) _commit = sha;
  } on Object {
    // not a checkout, or git is missing
  }
  return _commit;
}
