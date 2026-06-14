import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `session` — group action-log entries into named runs. One active
/// session at a time; opening a new one auto-closes the previous.
/// Ops: open / close / note / list / export.
class SessionTool extends GlintTool {
  const SessionTool();

  @override
  Tool get definition => Tool(
        name: 'session',
        description:
            'Group action-log entries into named runs (e.g. test scenarios). '
            'Ops: open (start), close (end active), note (annotate active), '
            'list (history + active), export (action-log slice for one session).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description: 'open | close | note | list | export',
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
          required: ['op'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = args['op']! as String;
    final mgr = session.sessions;
    final seq = session.actionLog.nextSequence;

    switch (op) {
      case 'open':
        final name = args['name'] as String?;
        if (name == null || name.isEmpty) {
          return _bad('op=open requires `name`');
        }
        final s = mgr.open(name, seq);
        session.telemetry.noteSession('open');
        return StructuredResponse(
          summary: 'opened session "$name" (id=${s.id}) at seq=$seq',
          data: {'session': s.toJson()},
        );

      case 'close':
        final s = mgr.close(seq);
        if (s == null) {
          return _bad('no active session to close');
        }
        session.telemetry.noteSession('close');
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
        if (!ok) return _bad('no active session to note');
        return StructuredResponse(
          summary: 'noted: $text',
          data: {'active': mgr.active?.toJson()},
        );

      case 'list':
        final all = mgr.history;
        return StructuredResponse(
          summary: all.isEmpty
              ? '(no sessions)'
              : all.map((s) => '${s.isActive ? "* " : "  "}'
                  '${s.id} "${s.name}" '
                  'seq=${s.firstSeq}..${s.lastSeq ?? "—"}').join('\n'),
          data: {
            'count': all.length,
            'active': mgr.active?.id,
            'sessions': all.map((s) => s.toJson()).toList(),
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
        return _bad(
            'unknown op: $op (use one of open / close / note / list / export)');
    }
  }

  StructuredResponse _bad(String msg) => StructuredResponse.error(
        summary: msg,
        errorKind: GlintErrorKind.invalidArgument,
      );
}
