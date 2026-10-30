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

  static const _defaultMaxChars = 600;
  static const _totalCapChars = 20000;

  @override
  Tool get definition => Tool(
        name: 'app_logs',
        description: 'Query the running app\'s log buffer (FlutterError dumps + '
            'developer.log + stderr writes). Use `errorsOnly` to surface only '
            'entries that look like exceptions / stack traces, and `contains` / '
            '`match` to find lines in a noisy app. Entries are cut at `maxChars` '
            'each and the reply at ~20000 chars; `seq` addresses the full entry.',
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
            'native': Schema.bool(
              description:
                  'Native crashes of the app since attach (iOS crash reports, Android crash buffer) instead of Dart logs.',
            ),
            'sinceSeq': Schema.int(
              description: 'Return entries with sequence >= sinceSeq.',
            ),
            'contains': Schema.string(
              description: 'Only entries containing this text (case-insensitive). Applied before limit.',
            ),
            'match': Schema.string(
              description:
                  'Only entries matching this Dart regex (content or logger name). Applied before limit; combine with contains to require both.',
            ),
            'maxChars': Schema.int(
              description:
                  'Cut each entry to this many chars, with a marker naming what was dropped. Default 600, 0 = no cap.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final limit = argInt(args, 'limit') ?? 50;
    final errorsOnly = argBool(args, 'errorsOnly') ?? false;
    final asJson = (args['format'] as String?) == 'json';
    final streamName = args['stream'] as String?;
    final sinceSeq = argInt(args, 'sinceSeq');
    final contains = _nonEmpty(args['contains']);
    final matchSource = _nonEmpty(args['match']);
    final maxChars = argInt(args, 'maxChars') ?? _defaultMaxChars;
    if (argBool(args, 'native') ?? false) return _nativeCrashes(session, asJson);

    AppLogStream? streamFilter;
    if (streamName != null) {
      streamFilter = AppLogStream.values.where((s) => s.name == streamName).firstOrNull;
      if (streamFilter == null) {
        return StructuredResponse.error(
          summary: 'unknown stream: $streamName',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use stderr or logging'],
        );
      }
    }

    if (maxChars < 0) {
      return StructuredResponse.error(
        summary: 'maxChars cannot be negative',
        errorKind: GlintErrorKind.invalidArgument,
        detail: 'got maxChars:$maxChars',
        nextSteps: const ['pass a positive maxChars, or 0 for no per-entry cap'],
      );
    }

    RegExp? pattern;
    if (matchSource != null) {
      try {
        pattern = RegExp(matchSource);
      } on FormatException catch (e) {
        return StructuredResponse.error(
          summary: 'match is not a valid regex',
          errorKind: GlintErrorKind.invalidArgument,
          detail: e.message,
          nextSteps: const [
            r'escape regex characters such as [ ] ( ) . with a backslash, e.g. match:"\[EventTracker\]"',
            'or use contains:"<text>" for a plain case-insensitive substring',
          ],
        );
      }
    }

    final scan = session.appLogs.scan(
      limit: limit,
      errorsOnly: errorsOnly,
      streamFilter: streamFilter,
      sinceSeq: sinceSeq,
      contains: contains,
      pattern: pattern,
    );
    final shown = _fitTotalCap(scan.entries.map((e) => _CutEntry(e, maxChars)).toList());
    final entries = [for (final c in shown) c.entry];
    final filtered = contains != null || pattern != null;

    final body = shown.isEmpty ? '(no entries)${_whyEmpty(session)}' : shown.map((c) => c.render()).join('\n');
    final summary = [
      if (filtered) '${scan.matched} of ${scan.scanned} entries matched ${_filterLabel(contains, matchSource)}',
      body,
    ].join('\n');

    final hidden = scan.matched - shown.length;
    return StructuredResponse(
      summary: summary,
      nextSteps: [
        if (shown.isEmpty) ..._emptyNextSteps(session, filtered: filtered && scan.scanned > 0),
        if (hidden > 0)
          '$hidden older matching entries not shown (limit or the ${_totalCapChars ~/ 1000}k char reply cap); narrow with contains/match or raise limit',
        if (shown.any((c) => c.cut > 0))
          'entries cut at $maxChars chars; pass maxChars:0 to read them whole (narrow with sinceSeq or contains first)',
      ],
      data: {
        'count': entries.length,
        'scanned': scan.scanned,
        'matched': scan.matched,
        'capacity': session.appLogs.capacity,
        'nextSequence': session.appLogs.nextSequence,
        // The rendered summary already carries the entries; only ship the
        // structured array when json is explicitly requested (matches `logs`).
        if (asJson) 'entries': shown.map((c) => c.toJson()).toList(),
      },
    );
  }

  /// Keeps the newest entries whose rendered text fits the reply cap, always at least one.
  List<_CutEntry> _fitTotalCap(List<_CutEntry> all) {
    var used = 0;
    var keepFrom = all.length;
    for (var i = all.length - 1; i >= 0; i--) {
      used += all[i].render().length + 1;
      if (used > _totalCapChars && keepFrom < all.length) break;
      keepFrom = i;
    }
    return all.sublist(keepFrom);
  }

  String? _nonEmpty(Object? value) => value is String && value.isNotEmpty ? value : null;

  String _filterLabel(String? contains, String? match) => [
        if (contains != null) '"$contains"',
        if (match != null) '/$match/',
      ].join(' and ');

  Future<StructuredResponse> _nativeCrashes(GlintSession session, bool asJson) async {
    final active = session.active;
    if (active == null) {
      return StructuredResponse.error(
        summary: 'not attached, so there is no app to read crashes for',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['call `attach` first'],
      );
    }
    final crashes = await active.nativeCrashes();
    return StructuredResponse(
      summary: crashes.isEmpty
          ? 'no native crashes of the app since attach'
          : [
              for (final c in crashes)
                '${c.time.toIso8601String().substring(11, 19)} ${c.reason}\n${c.frames.map((f) => '  at $f').join('\n')}',
            ].join('\n'),
      data: {
        'count': crashes.length,
        if (asJson) 'crashes': [for (final c in crashes) c.toJson()],
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

  List<String> _emptyNextSteps(GlintSession session, {required bool filtered}) {
    if (filtered) return const ['nothing matched; loosen contains/match, or drop errorsOnly/stream, or lower sinceSeq'];
    final active = session.active;
    if (active == null) return const ['attach (no args) to start collecting app logs'];
    if (!active.deviceMode) return const [];
    return const [
      'once the Flutter app runs in debug mode, attach without mode:"device" to collect its logs',
      'until then read logs where the app was launched (the flutter run output)',
    ];
  }
}

/// A log entry with its content cut to [maxChars] (0 = whole), remembering how much was dropped.
class _CutEntry {
  _CutEntry(this.entry, int maxChars) : cut = _dropped(entry, maxChars) {
    content = cut > 0 ? '${entry.content.substring(0, maxChars)}... [$cut more chars cut]' : entry.content;
  }

  static int _dropped(AppLogEntry entry, int maxChars) =>
      maxChars > 0 && entry.content.length > maxChars ? entry.content.length - maxChars : 0;

  final AppLogEntry entry;
  final int cut;
  late final String content;

  String render() {
    final e = entry;
    final tag = e.loggerName != null ? '${e.stream.name}:${e.loggerName}' : e.stream.name;
    return '[seq=${e.sequence} ${e.timestamp.toIso8601String()} $tag] $content';
  }

  Map<String, Object?> toJson() => {
        ...entry.toJson(),
        'content': content,
        if (cut > 0) 'truncatedChars': cut,
      };
}
