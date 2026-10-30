import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `session` — group action-log entries into named runs. One active
/// session at a time; opening a new one auto-closes the previous.
/// Ops: status / open / close / note / list / export / detach.
class SessionTool extends GlintTool {
  const SessionTool();

  /// `app` names the app to detach here, so it must not also bind the call to one.
  @override
  bool get routesByApp => false;

  @override
  Tool get definition => Tool(
        name: 'session',
        description: 'Session status and named runs. Ops: status (default: attached apps, '
            'with live:false and a reason for a device that is gone, active run, call counts), '
            'open (start a named run), close, note (annotate active), list (history), '
            'export (action-log slice for one run), detach (drop the active app, or `app:`, '
            'or `all:true`, and free its device; `attach device:"<id>"` brings it back).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description: 'status (default) | open | close | note | list | export | detach',
            ),
            'app': Schema.string(
              description: 'op=detach: the app to detach (device id, name, package or simulator). '
                  'Default: the active one.',
            ),
            'all': Schema.bool(
              description: 'op=detach: detach every attached app.',
            ),
            'name': Schema.string(
              description: 'Session name (required for op=open).',
            ),
            'text': Schema.string(
              description: 'Annotation text (required for op=note).',
            ),
            'sessionId': Schema.string(
              description: 'Target session (optional for export; defaults to active).',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'status';
    final mgr = session.sessions;
    final seq = session.actionLog.nextSequence;

    switch (op) {
      case 'status':
        final apps = session.apps;
        final active = session.active;
        final run = mgr.active;
        final gone = apps.isEmpty ? const <String, String>{} : await _goneReasons(apps);
        final attached = [
          for (final a in apps) _appJson(a, identical(a, active), gone[a.id]),
        ];
        return StructuredResponse(
          summary: [
            apps.isEmpty
                ? 'not attached'
                : 'attached: ${apps.map((a) => '${a.label} on ${a.deviceName ?? a.id}${identical(a, active) ? " (active)" : ""}${_flag(a, gone[a.id])}').join(", ")}',
            run == null ? 'no named run open' : 'run "${run.name}" open since seq=${run.firstSeq}',
            '$seq tool call(s) logged this process',
          ].join('\n'),
          nextSteps: [
            for (final a in apps)
              if (gone.containsKey(a.id))
                'session op:detach app:"${a.id}" drops it, or attach device:"${a.id}" relaunches it',
          ],
          data: {
            'attached': attached,
            'activeApp': active?.id,
            'run': run?.toJson(),
            'calls': seq,
            if (session.reconnectCount > 0) 'reconnectCount': session.reconnectCount,
          },
        );

      case 'detach':
        return _detach(session, args);

      case 'open':
        final name = args['name'] as String?;
        if (name == null || name.isEmpty) {
          return _bad('op=open requires `name`');
        }
        final s = mgr.open(name, seq);
        return StructuredResponse(
          summary: 'opened session "$name" (id=${s.id}) at seq=$seq',
          data: {'session': s.toJson()},
        );

      case 'close':
        final s = mgr.close(seq);
        if (s == null) {
          return _bad('no active session to close', const ['open one first: session op:open name:"..."']);
        }
        return StructuredResponse(
          summary: 'closed session "${s.name}" (id=${s.id}); '
              'spans seq=${s.firstSeq}..${s.lastSeq ?? seq - 1}',
          data: {'session': s.toJson()},
        );

      case 'note':
        final text = args['text'] as String?;
        if (text == null || text.isEmpty) {
          return _bad('op=note requires `text`');
        }
        final ok = mgr.note(text);
        if (!ok) {
          return _bad('no active session to note', const ['open one first: session op:open name:"..."']);
        }
        return StructuredResponse(
          summary: 'noted: $text',
          data: {'active': mgr.active?.toJson()},
        );

      case 'list':
        final all = mgr.history;
        return StructuredResponse(
          summary: all.isEmpty
              ? '(no sessions)'
              : all
                  .map((s) => '${s.isActive ? "* " : "  "}'
                      '${s.id} "${s.name}" '
                      'seq=${s.firstSeq}..${s.lastSeq ?? "—"}')
                  .join('\n'),
          data: {
            'count': all.length,
            'active': mgr.active?.id,
            'sessions': all.map((s) => s.toJson()).toList(),
            if (session.reconnectCount > 0) 'reconnectCount': session.reconnectCount,
          },
        );

      case 'export':
        final sessionId = args['sessionId'] as String? ?? mgr.active?.id;
        if (sessionId == null) {
          return _bad('no active session; pass `sessionId` or open one');
        }
        final s = mgr.byId(sessionId);
        if (s == null) return _bad('no session with id=$sessionId');
        final entries = session.actionLog
            .query(sinceSeq: s.firstSeq, limit: 1000)
            .where((e) => s.lastSeq == null || e.sequence <= s.lastSeq!)
            .toList();
        return StructuredResponse(
          summary: const LogRenderer().render(entries),
          data: {
            'session': s.toJson(),
            'entries': entries.map((e) => e.toJson()).toList(),
          },
        );

      default:
        return _bad('unknown op: $op (use one of status / open / close / note / list / export / detach)');
    }
  }

  StructuredResponse _bad(String msg, [List<String> nextSteps = const []]) => StructuredResponse.error(
        summary: msg,
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: nextSteps,
      );

  Future<Map<String, String>> _goneReasons(List<AppSession> apps) {
    final adb = apps.map((a) => a.device).whereType<AndroidDevice>().firstOrNull?.adbPath ?? 'adb';
    return DeviceDiscovery(adbPath: adb).goneReasons([for (final a in apps) (id: a.id, platform: a.platform)]);
  }

  Map<String, Object?> _appJson(AppSession app, bool active, String? goneReason) => {
        ...app.toJson(active: active),
        if (goneReason != null) ...{'live': false, 'gone': true, 'reason': goneReason} else if (!app.isLive)
          'reason': 'VM service connection lost',
      };

  String _flag(AppSession app, String? goneReason) {
    if (goneReason != null) return ' [gone: $goneReason]';
    return app.isLive ? '' : ' [VM connection lost]';
  }

  Future<StructuredResponse> _detach(GlintSession session, Map<String, Object?> args) async {
    final pooled = session.apps;
    if (pooled.isEmpty) {
      return StructuredResponse.error(
        summary: 'nothing is attached, so there is nothing to detach',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['call `attach` (no args) to discover and connect the running app'],
      );
    }
    final all = args['all'] == true;
    final name = args['app'] as String?;
    if (all && name != null) {
      return _bad('op=detach takes `app` or `all:true`, not both',
          const ['drop `app` to detach everything, or drop `all` to detach one app']);
    }
    final List<AppSession> targets;
    if (all) {
      targets = pooled;
    } else if (name != null) {
      final matches = session.matchApps(name);
      if (matches.length != 1) return GlintTool.unknownAppResponse(session, name, matches);
      targets = matches;
    } else if (session.active != null) {
      targets = [session.active!];
    } else {
      return StructuredResponse.error(
        summary: 'no active app and ${pooled.length} attached, so glint cannot tell which to detach',
        errorKind: GlintErrorKind.unknownApp,
        detail: 'attached: ${pooled.map((a) => "${a.label} on ${a.deviceName ?? a.id}").join(", ")}',
        nextSteps: [
          for (final a in pooled) 'session op:detach app:"${a.id}"  (${a.label} on ${a.deviceName ?? a.id})',
          'or session op:detach all:true',
        ],
      );
    }

    final detached = [for (final a in targets) a.toJson()];
    final launched = [
      for (final a in targets)
        if (session.launchedAppFor(a.id) != null) a
    ];
    for (final a in targets) {
      await session.detach(deviceId: a.id);
    }

    final active = session.active;
    final remaining = session.apps;
    final what = targets.map((a) => '${a.label} on ${a.deviceName ?? a.id}').join(', ');
    return StructuredResponse(
      summary: [
        'detached $what and released its device claim',
        active == null ? 'no active app' : 'active: ${active.label} on ${active.deviceName ?? active.id}',
        remaining.isEmpty
            ? 'nothing attached'
            : 'still attached: ${remaining.map((a) => '${a.label} on ${a.deviceName ?? a.id}').join(', ')}',
      ].join('\n'),
      nextSteps: [
        if (remaining.isNotEmpty && active == null)
          'pick one: ${remaining.map((a) => 'attach app:"${a.deviceName ?? a.id}"').join(' or ')}',
        for (final a in launched)
          'glint launched ${a.label} and it keeps running: `kill_app device:"${a.id}"` stops it',
        'attach device:"${targets.first.id}" brings ${targets.length == 1 ? 'it' : 'the first'} back',
      ],
      data: {
        'detached': detached,
        'activeApp': active?.id,
        'attached': session.appsJson(),
      },
    );
  }
}
