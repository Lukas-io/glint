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

  static const _maxConditions = 10;
  static const _maxEventsLimit = 200;

  @override
  Tool get definition => Tool(
        name: 'watch',
        description:
            'Register conditions, return at once, and be woken later: glint appends one JSON line per event to an events file, and you follow it by running the `tail -n0 -F <file>` line from nextSteps as a background shell monitor (clients do not show server notifications to an idle model). '
            'For handing the app to a human ("sign in, then I take over") or waiting minutes on a backend change; wait_for blocks one call for 120 s at most. '
            'op: add (default; conditions:[…], any one matching fires), list, cancel (id, or all:true), events (sinceSeq, for clients that poll instead of tailing). '
            'Conditions: {text|glintId, state:appears|disappears}, {route:"/home"} (empty = any change), {overlay:appears|dismisses} (dialog, sheet, system surface), {log:"<regex>"} (new app log lines). '
            'Options: label, once (default true; false keeps firing), timeoutMs (default 1800000, max 21600000). Scene conditions are read about every 1.5 s, backing off while the app is locked or unresponsive. '
            'A watch ends with an `ended` event on timeout, cancel or detach. errorKind: invalidArgument, flutterModeRequired (device mode), sessionNotAttached.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'add | list | cancel | events. Default add.'),
            'conditions': Schema.list(
              description:
                  'op=add: up to $_maxConditions, each exactly one of text, glintId, route, overlay, log (state goes with text or glintId). Any one matching fires the watch.',
              items: ObjectSchema(
                properties: {
                  'text': Schema.string(description: 'Visible text, matched as tap text: does (exact, then contains).'),
                  'glintId': Schema.string(description: 'Id to watch instead of text.'),
                  'state': Schema.string(description: 'With text or glintId: appears (default) | disappears.'),
                  'route':
                      Schema.string(description: 'Route change; the route name to wait for, or empty for any change.'),
                  'overlay': Schema.string(description: 'appears | dismisses (dialog, sheet or system surface).'),
                  'log': Schema.string(description: 'Regex matched against each new app log line.'),
                },
              ),
            ),
            'label': Schema.string(description: 'op=add: your note on why, echoed in every event.'),
            'once': Schema.bool(description: 'op=add: end after the first match. Default true.'),
            'timeoutMs': Schema.int(description: 'op=add: 1000-21600000. Default 1800000 (30 min).'),
            'id': Schema.string(description: 'op=cancel: watch id from add or list. op=events: only that watch.'),
            'all': Schema.bool(description: 'op=cancel: cancel every watch (of the targeted app when app is given).'),
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
      'add' => _add(session, args),
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

  Future<StructuredResponse> _add(GlintSession session, Map<String, Object?> args) async {
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
    final app = session.active;
    if (app == null) throw SessionNotAttachedError(missing: 'watch');
    if (app.deviceMode) {
      return StructuredResponse.error(
        summary: 'device mode has no Flutter tree or app logs to watch',
        errorKind: GlintErrorKind.flutterModeRequired,
        nextSteps: const ['attach to the Flutter debug app (without mode:"device")'],
      );
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
    final once = argBool(args, 'once') ?? true;
    final added = await registry.add(
      app,
      conditions: parsed.conditions!,
      label: label,
      timeoutMs: timeoutMs,
      once: once,
    );
    final watch = added.watch;
    final path = registry.events.path;
    final fileError = registry.events.fileError;
    final monitor = 'tail -n0 -F $path';
    final matchedNow = added.firedNow.where((e) => e['kind'] == 'match').toList();
    final over = watch.ended;
    return StructuredResponse(
      summary: [
        '${over ? 'matched at once' : 'watching'} ${app.label} as ${watch.id}'
            '${label == null ? '' : ' ("$label")'}: ${watch.conditions.map((c) => c.spec.describe).join('; ')}',
        '${once ? 'once' : 'repeating'} · ${WatchRegistry.span(timeoutMs)} · events in $path',
        for (final e in matchedNow) 'already true: ${e['condition']} (${e['matched']})',
      ].join('\n'),
      warnings: [
        if (fileError != null) 'the events file cannot be written ($fileError); poll with watch op:events instead',
        if (added.readNote != null)
          'could not read ${app.label} yet (${added.readNote}); the watch keeps trying and backs off meanwhile',
      ],
      nextSteps: [
        if (over)
          'it already matched and ended: the event is in data.firedNow, nothing to monitor'
        else if (fileError == null)
          'run `$monitor` as a background monitor; each line is one event (kind match or ended)',
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
    final scoped = request.arguments?['app'] != null ? session.active : null;
    final watches = [
      for (final w in registry.active)
        if (scoped == null || identical(w.app, scoped)) w,
    ];
    return StructuredResponse(
      summary: watches.isEmpty
          ? 'no active watches'
          : [
              for (final w in watches)
                '${w.id}${w.label == null ? '' : ' "${w.label}"'} on ${w.app.label} · ${_state(registry, w)} · '
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
    final scoped = request.arguments?['app'] != null ? session.active : null;
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
    return e['kind'] == 'ended'
        ? '$head ${e['reason']}${e['detail'] == null ? '' : ': ${e['detail']}'}'
        : '$head ${e['condition']}: ${e['matched']}${e['route'] == null ? '' : ' (route ${e['route']})'}';
  }

  static String _state(WatchRegistry registry, Watch w) {
    if (!w.needsScene) return 'listening to logs';
    final hold = registry.holdReason(w.app);
    return hold == null ? 'reading about every 1.5 s' : 'backing off: $hold';
  }

  static Map<String, Object?> _watchJson(WatchRegistry registry, Watch w) => {
        'id': w.id,
        if (w.label != null) 'label': w.label,
        'app': w.app.label,
        'conditions': [for (final c in w.conditions) c.spec.toJson()],
        'once': w.once,
        'timeoutMs': w.timeoutMs,
        'expiresAt': w.expiresAt.toUtc().toIso8601String(),
        'matches': w.matches,
        'state': w.ended ? 'ended' : (w.needsScene && registry.holdReason(w.app) != null ? 'backoff' : 'armed'),
        if (w.needsScene && registry.holdReason(w.app) != null) 'holdReason': registry.holdReason(w.app),
      };
}
