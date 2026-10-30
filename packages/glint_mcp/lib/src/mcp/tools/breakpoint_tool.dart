import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// `breakpoint` pauses the app when one of its log lines matches a regex, screenshots that moment, and resumes on command.
class BreakpointTool extends GlintTool {
  const BreakpointTool();

  static const _defaultTimeoutMs = 60000;
  static const _maxTimeoutMs = 120000;
  static const _progressEvery = Duration(seconds: 15);

  @override
  Tool get definition => Tool(
        name: 'breakpoint',
        description:
            'Pause the app the moment it logs a line matching a regex (print, debugPrint, developer.log, stderr), screenshot that screen, and resume on command. '
            'op: set (arm pattern), wait (block until the next hit, timeoutMs default 60000, max 120000, progress every 15 s), status (current hit, no wait), resume (continue the app and consume the hit), list, clear (id, or all). '
            'While paused the app cannot draw or answer get_scene, so take what you need from the hit, then resume. glint resumes a paused app when it detaches. '
            'errorKind: invalidArgument (bad regex or op), targetNeverReady (wait timed out), flutterModeRequired (device mode has no logs), backendToolError (the VM refused pause or resume).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'set | wait | status | resume | list | clear. Default status.'),
            'pattern': Schema.string(
                description: 'op=set: regex matched against each log line, e.g. "\\[EventTracker\\] vip_".'),
            'stream': Schema.string(description: 'op=set: only lines from stdout, stderr or logging. Default all.'),
            'pause': Schema.bool(description: 'op=set: pause the app on a hit. Default true; false only records hits.'),
            'once': Schema.bool(description: 'op=set: remove the breakpoint after its first hit. Default false.'),
            'caseSensitive': Schema.bool(description: 'op=set: default true.'),
            'id': Schema.string(description: 'op=clear: breakpoint id from set or list. Omit to clear all.'),
            'timeoutMs': Schema.int(description: 'op=wait: 100-120000. Default 60000.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final app = session.active;
    if (app == null) throw SessionNotAttachedError(missing: 'breakpoint');
    if (app.deviceMode) {
      return StructuredResponse.error(
        summary: 'device mode has no VM connection, so there are no app logs to break on',
        errorKind: GlintErrorKind.flutterModeRequired,
        nextSteps: const ['attach to the Flutter debug app (without mode:"device")'],
      );
    }
    final bps = app.breakpoints;
    final op = (args['op'] as String?) ?? 'status';
    return switch (op) {
      'set' => _set(bps, args),
      'wait' => _wait(session, request, app, args),
      'status' => _status(bps),
      'resume' => _resume(bps),
      'list' => _list(bps),
      'clear' => _clear(bps, args['id'] as String?),
      _ => StructuredResponse.error(
          summary: 'unknown op: $op',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use set, wait, status, resume, list or clear'],
        ),
    };
  }

  StructuredResponse _set(LogBreakpoints bps, Map<String, Object?> args) {
    final pattern = args['pattern'] as String?;
    if (pattern == null || pattern.isEmpty) {
      return StructuredResponse.error(
        summary: 'op=set needs a pattern',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass pattern:"<regex>", e.g. pattern:"\\[EventTracker\\]"'],
      );
    }
    final RegExp regex;
    try {
      regex = RegExp(pattern, caseSensitive: argBool(args, 'caseSensitive') ?? true);
    } on FormatException catch (e) {
      return StructuredResponse.error(
        summary: 'pattern is not a valid regex',
        errorKind: GlintErrorKind.invalidArgument,
        detail: e.message,
        nextSteps: const ['escape regex characters such as [ ] ( ) . with a backslash'],
      );
    }
    AppLogStream? stream;
    final streamName = args['stream'] as String?;
    if (streamName != null) {
      stream = AppLogStream.values.where((s) => s.name == streamName).firstOrNull;
      if (stream == null) {
        return StructuredResponse.error(
          summary: 'unknown stream: $streamName',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use stdout, stderr or logging, or omit it'],
        );
      }
    }
    final bp =
        bps.add(regex, stream: stream, pause: argBool(args, 'pause') ?? true, once: argBool(args, 'once') ?? false);
    return StructuredResponse(
      summary: 'breakpoint ${bp.id} armed on /$pattern/${stream == null ? '' : ' (${stream.name})'}'
          '${bp.pause ? ', pauses the app' : ', records only'}${bp.once ? ', once' : ''}',
      nextSteps: const ['trigger the line in the app, then breakpoint op:wait'],
      data: {'breakpoint': bp.toJson(), 'breakpointCount': bps.armed.length},
    );
  }

  Future<StructuredResponse> _wait(
      GlintSession session, CallToolRequest request, AppSession app, Map<String, Object?> args) async {
    final bps = app.breakpoints;
    final timeoutMs = argInt(args, 'timeoutMs') ?? _defaultTimeoutMs;
    if (timeoutMs < 100 || timeoutMs > _maxTimeoutMs) {
      return StructuredResponse.error(
        summary: 'timeoutMs must be between 100 and $_maxTimeoutMs',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['omit it for the 60000 ms default'],
      );
    }
    if (bps.armed.isEmpty && !bps.hasPending) {
      return StructuredResponse.error(
        summary: 'no breakpoint is armed, so nothing can hit',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['breakpoint op:set pattern:"<regex>" first'],
      );
    }
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    final start = DateTime.now();
    final deadline = start.add(Duration(milliseconds: timeoutMs));
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final hit = await bps.next(left < _progressEvery ? left : _progressEvery);
      if (hit != null) return _hitResponse(bps, hit);
      final sec = DateTime.now().difference(start).inSeconds;
      if (token != null && notifier != null) {
        notifier(ProgressNotification(
            progressToken: token, progress: sec, message: 'waiting for a breakpoint hit on ${app.label} (${sec}s)'));
      }
    }
    return StructuredResponse.error(
      summary: 'no breakpoint hit within ${timeoutMs ~/ 1000} s',
      errorKind: GlintErrorKind.targetNeverReady,
      detail: 'armed: ${bps.armed.map((b) => '${b.id} /${b.pattern.pattern}/').join(', ')}',
      nextSteps: const [
        'trigger the action that logs the line, then wait again',
        'app_logs to check the line is logged and the pattern matches it',
      ],
    );
  }

  StructuredResponse _status(LogBreakpoints bps) {
    final hit = bps.ready;
    if (hit != null) return _hitResponse(bps, hit);
    return StructuredResponse(
      summary: bps.isPaused
          ? 'pausing the app for hit ${bps.pausedFor!.number}'
          : 'no hit pending · ${bps.armed.length} armed',
      nextSteps: [if (bps.armed.isEmpty) 'breakpoint op:set pattern:"<regex>" to arm one' else 'breakpoint op:wait'],
      data: {
        'paused': bps.isPaused,
        'breakpoints': [for (final b in bps.armed) b.toJson()]
      },
    );
  }

  StructuredResponse _hitResponse(LogBreakpoints bps, BreakpointHit hit) {
    final waiting = bps.pending.length - 1;
    return StructuredResponse(
      summary: '${hit.paused ? 'paused at' : 'hit'} ${hit.breakpoint.id} (hit ${hit.number}): ${hit.matchedLine}',
      warnings: [
        if (hit.pauseError != null) 'the app could not be paused: ${hit.pauseError}',
        if (hit.breakpoint.pause && hit.screenshotPath == null) 'no screenshot was captured at the hit',
        if (hit.alsoMatched.isNotEmpty)
          '${hit.alsoMatched.length} more line(s) matched while paused; see data.hit.alsoMatched',
      ],
      nextSteps: [
        if (hit.screenshotPath != null) 'the screen at the hit is at ${hit.screenshotPath}',
        hit.paused ? 'breakpoint op:resume to continue the app' : 'breakpoint op:resume to consume this hit',
        if (waiting > 0) '$waiting more hit(s) queued; wait again after resuming',
      ],
      data: {'hit': hit.toJson(), 'queued': waiting},
    );
  }

  Future<StructuredResponse> _resume(LogBreakpoints bps) async {
    final r = await bps.resume();
    if (r.error != null) {
      return StructuredResponse.error(
        summary: 'the app could not be resumed',
        errorKind: GlintErrorKind.backendToolError,
        detail: r.error,
        nextSteps: const ['retry breakpoint op:resume', 'or resume from the debugger / `flutter run`'],
      );
    }
    final hit = r.hit;
    return StructuredResponse(
      summary: hit == null ? 'nothing to resume' : 'resumed after hit ${hit.number} (${hit.breakpoint.id})',
      nextSteps: [
        if (bps.ready != null)
          'another hit is queued: breakpoint op:status'
        else if (bps.armed.isNotEmpty)
          'breakpoint op:wait for the next hit',
      ],
      data: {'paused': bps.isPaused, 'queued': bps.pending.length},
    );
  }

  StructuredResponse _list(LogBreakpoints bps) => StructuredResponse(
        summary: bps.armed.isEmpty
            ? 'no breakpoints armed'
            : bps.armed
                .map((b) => '${b.id} /${b.pattern.pattern}/ hits:${b.hits}${b.pause ? '' : ' (records only)'}')
                .join('\n'),
        data: {
          'breakpoints': [for (final b in bps.armed) b.toJson()],
          'paused': bps.isPaused,
          'queued': bps.pending.length
        },
      );

  StructuredResponse _clear(LogBreakpoints bps, String? id) {
    final removed = bps.remove(id);
    if (!removed && id != null) {
      return StructuredResponse.error(
        summary: 'no breakpoint $id',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['breakpoint op:list to see the armed ids'],
      );
    }
    return StructuredResponse(
      summary: id == null ? 'cleared all breakpoints' : 'cleared $id',
      nextSteps: [if (bps.isPaused) 'the app is still paused: breakpoint op:resume'],
      data: {'breakpointCount': bps.armed.length, 'paused': bps.isPaused},
    );
  }
}
