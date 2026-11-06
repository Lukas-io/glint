import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';
import '../watch_conditions.dart';
import '../watch_registry.dart';

/// Registers conditions on an app and returns at once; matches are appended as JSON lines to an events file a background shell monitor can follow.
class WatchTool extends GlintTool {
  const WatchTool();

  /// Watches only observe; they write glint's events file.
  @override
  bool changesDevice(Map<String, Object?> args) => false;

  @override
  bool get acceptsAllApps => true;

  static const _maxConditions = 10;
  static const _maxEventsLimit = 200;

  @override
  Tool get definition => Tool(
        name: 'watch',
        description:
            'Hand the app to a human or a backend and be woken when it reacts (PIN, password, 2FA, sign-in, confirming a real-money or destructive step, a teammate\'s change): register the screen that follows their action, then ask them and end the turn. wait_for blocks one call for 120 s at most and is for what you just caused. '
            'Returns at once; glint appends one JSON line per event to an events file, and you follow it by running the `tail -n0 -F <file>` line from nextSteps as a background shell monitor (clients do not show server notifications to an idle model). '
            'op: add (default; conditions:[…], any one matching fires), list, cancel (id, or all:true), events (sinceSeq, for clients that poll instead of tailing). '
            'Conditions: {text|glintId, state:appears|disappears}, {route:"/home"} (empty = any change), {overlay:appears|dismisses} (dialog, sheet, system surface), {log:"<regex>"} (new app log lines), {errors:true} (each new distinct Flutter error, with its summary and file:line; repeats stay quiet), {alerts:["error","uncaught","overflow","http","terminated"]} (what the app reports itself, read from the framework and the VM, not its logs: overflow carries amount and edge, http is a 4xx/5xx or transport failure with method, url and status, terminated says the app died and why; disconnected is opt-in and reports a lost VM connection and its return, never counted as terminated), {lint:true|[rules]} (UX lint of the live layout, kind lint events: overflow, keyboard (focused field under the keyboard), insets (content under the status bar or home indicator), tapTarget (under minTapTarget, default 44), clippedText, lines (headline past maxHeadlineLines, default 2); each finding has the rule, widget, glintId, file:line and measured numbers, once per problem; checked when the screen changes and has settled, off unless armed; a lintError event with errorKind, detail and nextSteps when the check cannot run: once, then glint retries unless it did not compile). '
            'allApps:true (or app:"*") takes alert conditions only and covers every attached app, apps attached later included; each event names app and device, and one `op:events` drains them all. '
            'Options: label, once (default true; false for allApps or lint), timeoutMs (default 1800000, max 21600000). Scene conditions are read about every 1.5 s, backing off while the app is locked or unresponsive. '
            'A watch ends with an `ended` event on timeout, cancel or detach. errorKind: invalidArgument, flutterModeRequired (device mode), sessionNotAttached.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'add | list | cancel | events. Default add.'),
            'conditions': Schema.list(
              description:
                  'op=add: up to $_maxConditions, each exactly one of text, glintId, route, overlay, log, errors, alerts, lint (state goes with text or glintId). Any one matching fires the watch.',
              items: ObjectSchema(
                properties: {
                  'text': Schema.string(description: 'Visible text, matched as tap text: does (exact, then contains).'),
                  'glintId': Schema.string(description: 'Id to watch instead of text.'),
                  'state': Schema.string(description: 'With text or glintId: appears (default) | disappears.'),
                  'route':
                      Schema.string(description: 'Route change; the route name to wait for, or empty for any change.'),
                  'overlay': Schema.string(description: 'appears | dismisses (dialog, sheet or system surface).'),
                  'log': Schema.string(description: 'Regex matched against each new app log line.'),
                  'errors':
                      Schema.bool(description: 'true: fire once for each new distinct app error; repeats do not fire.'),
                  'alerts': Schema.list(
                    description:
                        'Any of error, uncaught, overflow, http, terminated, disconnected (opt-in). errors:true is error + uncaught + overflow.',
                    items: Schema.string(),
                  ),
                  'lint': Schema.combined(
                    description:
                        'true for every rule, or a list of overflow, keyboard, insets, tapTarget, clippedText, lines. Fires a lint event once per problem and route.',
                  ),
                  'minTapTarget':
                      Schema.num(description: 'With lint: smallest tap target side in logical points. Default 44.'),
                  'maxHeadlineLines':
                      Schema.int(description: 'With lint: lines a headline (font size 20+) may wrap to. Default 2.'),
                },
              ),
            ),
            'allApps': Schema.bool(
              description: 'op=add: watch every attached app and every app attached later; alert conditions only.',
            ),
            'label': Schema.string(description: 'op=add: your note on why, echoed in every event.'),
            'once': Schema.bool(
                description: 'op=add: end after the first match. Default true, false with allApps or lint.'),
            'timeoutMs': Schema.int(description: 'op=add: 1000-21600000. Default 1800000 (30 min).'),
            'id': Schema.string(description: 'op=cancel: watch id from add or list. op=events: only that watch.'),
            'all': Schema.bool(
                description:
                    'op=cancel: cancel every watch (those of the named app only when app is given; app:"*" cancels all-apps watches too).'),
            'sinceSeq': Schema.int(description: 'op=events: only events after this seq. Default 0.'),
            'limit': Schema.int(description: 'op=events: 1-$_maxEventsLimit. Default 50.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'add';
    return switch (op) {
      'add' => _add(session, args, request),
      'list' => _list(session, request),
      'cancel' => _cancel(session, args, request),
      'events' => _events(session, args),
      _ => StructuredResponse.error(
          summary: 'unknown op: $op',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use add, list, cancel or events'],
        ),
    };
  }

  Future<StructuredResponse> _add(GlintSession session, Map<String, Object?> args, CallToolRequest request) async {
    final parsed = parseWatchConditions(args['conditions'], max: _maxConditions);
    if (parsed.error != null) return parsed.error!;
    final timeoutMs = argInt(args, 'timeoutMs') ?? WatchRegistry.defaultTimeoutMs;
    if (timeoutMs < 1000 || timeoutMs > WatchRegistry.maxTimeoutMs) {
      return StructuredResponse.error(
        summary: 'timeoutMs must be between 1000 and ${WatchRegistry.maxTimeoutMs} (6 h)',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['omit it for the 30 min default'],
      );
    }
    final allApps = argBool(args, 'allApps') == true || args['app'] == '*';
    AppSession? app;
    if (allApps) {
      final scene = parsed.conditions!.where((c) => c is! AlertsCondition).toList();
      if (scene.isNotEmpty) {
        return StructuredResponse.error(
          summary: 'allApps watches take alert conditions only',
          errorKind: GlintErrorKind.invalidArgument,
          detail: 'not alerts: ${scene.map((c) => c.describe).join('; ')}',
          nextSteps: const [
            'use conditions:[{errors:true}] or [{alerts:["error","uncaught","overflow","http","terminated"]}] with allApps:true',
            'or drop allApps and watch the one app with app:"<name>"',
          ],
        );
      }
    } else {
      app = session.active;
      if (app == null) throw SessionNotAttachedError(missing: 'watch');
      if (app.deviceMode) {
        return StructuredResponse.error(
          summary: 'device mode has no Flutter tree or app logs to watch',
          errorKind: GlintErrorKind.flutterModeRequired,
          nextSteps: const ['attach to the Flutter debug app (without mode:"device")'],
        );
      }
    }
    final registry = session.watches;
    if (registry.active.length >= WatchRegistry.maxWatches) {
      return StructuredResponse.error(
        summary: '${registry.active.length} watches are already active',
        errorKind: GlintErrorKind.invalidArgument,
        detail: registry.active.map((w) => w.id).join(', '),
        nextSteps: const ['watch op:cancel id:"<id>" or all:true, then add again'],
      );
    }
    final label = args['label'] as String?;
    final once = argBool(args, 'once') ?? !(allApps || parsed.conditions!.any((c) => c is LintCondition));
    final added = await registry.add(
      app,
      conditions: parsed.conditions!,
      label: label,
      timeoutMs: timeoutMs,
      once: once,
      progress: _progressSink(session, request),
    );
    final watch = added.watch;
    final path = registry.events.path;
    final fileError = registry.events.fileError;
    final monitor = 'tail -n0 -F $path';
    final matchedNow = added.firedNow.where((e) => e['kind'] == 'match').toList();
    final over = watch.ended;
    return StructuredResponse(
      summary: [
        '${over ? 'matched at once' : 'watching'} ${watch.target} as ${watch.id}'
            '${label == null ? '' : ' ("$label")'}: ${watch.conditions.map((c) => c.spec.describe).join('; ')}',
        '${once ? 'once' : 'repeating'} · ${WatchRegistry.span(timeoutMs)} · events in $path',
        if (allApps)
          session.apps.where((a) => !a.deviceMode).isEmpty
              ? 'no app is attached yet; the watch starts on each app as it attaches'
              : 'covering ${session.apps.where((a) => !a.deviceMode).map((a) => a.label).join(', ')}, and apps attached later',
        for (final e in matchedNow) 'already true: ${e['condition']} (${e['matched']})',
      ].join('\n'),
      warnings: [
        if (fileError != null) 'the events file cannot be written ($fileError); poll with watch op:events instead',
        if (added.readNote != null)
          'could not read ${app?.label} yet (${added.readNote}); the watch keeps trying and backs off meanwhile',
        ...added.alertNotes,
      ],
      nextSteps: [
        if (over)
          'it already matched and ended: the event is in data.firedNow, nothing to monitor'
        else if (fileError == null)
          'run `$monitor` as a background monitor; each line is one event (kind match, lint, note or ended)',
        if (!over) 'or poll: watch op:events sinceSeq:${registry.events.lastSeq}',
        if (!over) 'watch op:cancel id:"${watch.id}" when you no longer need it',
      ],
      data: {
        'watch': _watchJson(registry, watch),
        'eventsFile': path,
        'monitor': monitor,
        'lastSeq': registry.events.lastSeq,
        if (added.observation != null)
          'now': {
            'route': added.observation!.route,
            'overlay': added.observation!.overlay,
          },
        if (added.firedNow.isNotEmpty) 'firedNow': added.firedNow,
      },
    );
  }

  StructuredResponse _list(GlintSession session, CallToolRequest request) {
    final registry = session.watches;
    final watches = _listed(session, request);
    return StructuredResponse(
      summary: watches.isEmpty
          ? 'no active watches'
          : [
              for (final w in watches)
                '${w.id}${w.label == null ? '' : ' "${w.label}"'} on ${w.target} · ${_state(registry, w)} · '
                    '${w.once ? 'once' : 'repeating'} · ${WatchRegistry.timeLeft(w)} left · ${w.matches} match(es) · '
                    '${w.conditions.map((c) => c.spec.describe).join('; ')}',
            ].join('\n'),
      nextSteps: [
        if (watches.isEmpty) 'watch conditions:[…] to register one' else 'tail -n0 -F ${registry.events.path}',
      ],
      data: {
        'watches': [for (final w in watches) _watchJson(registry, w)],
        'eventsFile': registry.events.path,
        'lastSeq': registry.events.lastSeq,
      },
    );
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (sec, phase) =>
        notifier(ProgressNotification(progressToken: token, progress: sec, message: '$phase (${sec}s)'));
  }

  List<Watch> _listed(GlintSession session, CallToolRequest request) {
    final requested = request.arguments?['app'];
    final active = session.watches.active;
    if (requested == null || requested == '*') return active;
    final scoped = session.active;
    return [
      for (final w in active)
        if (w.allApps || identical(w.app, scoped)) w,
    ];
  }

  StructuredResponse _cancel(GlintSession session, Map<String, Object?> args, CallToolRequest request) {
    final registry = session.watches;
    final id = args['id'] as String?;
    final all = argBool(args, 'all') ?? false;
    if ((id == null) == !all) {
      return StructuredResponse.error(
        summary: 'op=cancel takes exactly one of id or all:true',
        errorKind: GlintErrorKind.invalidArgument,
        detail: 'active: ${registry.active.isEmpty ? 'none' : registry.active.map((w) => w.id).join(', ')}',
        nextSteps: const ['watch op:cancel id:"w1"', 'or watch op:cancel all:true'],
      );
    }
    if (id != null) {
      if (!registry.cancel(id)) {
        return StructuredResponse.error(
          summary: 'no active watch $id',
          errorKind: GlintErrorKind.invalidArgument,
          detail: 'active: ${registry.active.isEmpty ? 'none' : registry.active.map((w) => w.id).join(', ')}',
          nextSteps: const ['watch op:list for the live ids; a watch that matched once or timed out is already gone'],
        );
      }
      return StructuredResponse(
        summary: 'cancelled $id',
        data: {
          'cancelled': [id],
          'active': registry.active.length
        },
      );
    }
    final requested = request.arguments?['app'];
    final scoped = requested == null || requested == '*' ? null : session.active;
    final ids = [
      for (final w in registry.active)
        if (scoped == null || identical(w.app, scoped)) w.id,
    ];
    registry.cancelAll(app: scoped);
    return StructuredResponse(
      summary: ids.isEmpty ? 'no active watches to cancel' : 'cancelled ${ids.join(', ')}',
      data: {'cancelled': ids, 'active': registry.active.length},
    );
  }

  StructuredResponse _events(GlintSession session, Map<String, Object?> args) {
    final log = session.watches.events;
    final since = argInt(args, 'sinceSeq') ?? 0;
    final limit = argInt(args, 'limit') ?? 50;
    if (limit < 1 || limit > _maxEventsLimit) {
      return StructuredResponse.error(
        summary: 'limit must be between 1 and $_maxEventsLimit',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['omit it for the 50 default'],
      );
    }
    final found = log.since(since, watch: args['id'] as String?, limit: limit);
    final next = found.isEmpty ? since : found.last['seq']! as int;
    final lost = since + 1 < log.oldestSeq && log.lastSeq > since;
    return StructuredResponse(
      summary: found.isEmpty ? 'no events after seq $since' : found.map(_eventLine).join('\n'),
      warnings: [
        if (lost) 'events ${since + 1}-${log.oldestSeq - 1} are no longer held in memory; read ${log.path} for them',
      ],
      nextSteps: [
        if (found.isNotEmpty) 'next poll: watch op:events sinceSeq:$next',
        if (found.isEmpty && session.watches.active.isNotEmpty)
          'still watching: ${session.watches.active.map((w) => w.id).join(', ')}',
      ],
      data: {'events': found, 'lastSeq': log.lastSeq, 'nextSinceSeq': next},
    );
  }

  static String _eventLine(Map<String, Object?> e) {
    final head = '#${e['seq']} ${e['watch']} ${e['kind']}';
    final where = e['app'] == null ? '' : ' [${e['app']}]';
    return switch (e['kind']) {
      'ended' => '$head ${e['reason']}${e['detail'] == null ? '' : ': ${e['detail']}'}',
      'note' => '$head$where ${e['detail']}',
      _ =>
        '$head$where ${e['alert'] ?? e['condition']}: ${e['matched']}${e['route'] == null ? '' : ' (route ${e['route']})'}',
    };
  }

  static String _state(WatchRegistry registry, Watch w) {
    if (!w.needsScene) return 'listening to logs and alerts';
    final hold = registry.holdReason(w.app!);
    return hold == null ? 'reading about every 1.5 s' : 'backing off: $hold';
  }

  static Map<String, Object?> _watchJson(WatchRegistry registry, Watch w) => {
        'id': w.id,
        if (w.label != null) 'label': w.label,
        'app': w.target,
        if (w.allApps) 'allApps': true,
        'conditions': [for (final c in w.conditions) c.spec.toJson()],
        'once': w.once,
        'timeoutMs': w.timeoutMs,
        'expiresAt': w.expiresAt.toUtc().toIso8601String(),
        'matches': w.matches,
        'state': w.ended ? 'ended' : (w.needsScene && registry.holdReason(w.app!) != null ? 'backoff' : 'armed'),
        if (w.needsScene && registry.holdReason(w.app!) != null) 'holdReason': registry.holdReason(w.app!),
      };
}
