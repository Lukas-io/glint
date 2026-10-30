import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../perception.dart' show appBusyCause;
import '../../../semantic.dart' show Inert;
import '../envelope.dart';
import '../session.dart';
import '../text_target.dart';
import '../tool.dart';
import '../tool_args.dart';

/// Blocks until an app shows (or stops showing) a text or glintId; with `app:` it watches another attached device, so one device can wait for what another caused.
class WaitForTool extends GlintTool {
  const WaitForTool();

  static const _defaultTimeoutMs = 15000;
  static const _maxTimeoutMs = 120000;
  static const _poll = Duration(milliseconds: 400);
  static const _progressEvery = Duration(seconds: 15);

  @override
  Tool get definition => Tool(
        name: 'wait_for',
        description:
            'Wait until the app shows a text or glintId, or with gone:true until it is gone. With app:"<name>" it watches another attached app, so in a batch one device can wait for what another caused ("B shows Incoming call"). timeoutMs default 15000, max 120000; progress every 15 s. errorKind: targetNeverReady (timed out; detail lists the text on screen), invalidArgument, flutterModeRequired (device mode).',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(
              description: 'Visible text to wait for, matched as tap text: does (exact, then contains).',
            ),
            'glintId': Schema.string(description: 'Id to wait for instead of text.'),
            'gone': Schema.bool(description: 'Wait until it disappears instead. Default false.'),
            'timeoutMs': Schema.int(description: 'How long to wait, 100-120000. Default 15000.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final text = args['text'] as String?;
    final glintId = args['glintId'] as String?;
    final gone = argBool(args, 'gone') ?? false;
    final timeoutMs = argInt(args, 'timeoutMs') ?? _defaultTimeoutMs;
    if ((text == null) == (glintId == null)) {
      return StructuredResponse.error(
        summary: 'wait_for takes exactly one of text or glintId',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass text:"Incoming call" or glintId:"<id>"'],
      );
    }
    if (timeoutMs < 100 || timeoutMs > _maxTimeoutMs) {
      return StructuredResponse.error(
        summary: 'timeoutMs must be between 100 and $_maxTimeoutMs',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['omit it for the 15000 ms default'],
      );
    }

    final what = text != null ? '"$text"' : glintId!;
    final where = session.active?.label ?? 'the app';
    final progress = _progressSink(session, request);
    final start = DateTime.now();
    var lastProgress = start;
    var visible = const <String>[];
    while (true) {
      ({String glintId, String label})? seen;
      try {
        seen = await session.withScene((scene) async {
          visible = visibleLabels(scene);
          if (text != null) {
            final matches = textMatches(scene, text).where((m) => m.inert != Inert.hidden).toList();
            return matches.isEmpty ? null : (glintId: matches.first.glintId, label: matches.first.label);
          }
          final node = scene.sourceScene.findByGlintId(glintId!);
          return node == null ? null : (glintId: glintId, label: node.textPreview ?? glintId);
        }, detail: SceneDetail.interactive);
      } on Object catch (e) {
        final busy = appBusyCause(e);
        if (busy == null) rethrow;
        if (DateTime.now().difference(start).inMilliseconds >= timeoutMs) {
          return StructuredResponse.appBusy(busy.timeout, summary: '$where stayed busy while waiting for $what');
        }
        progress?.call(
            DateTime.now().difference(start).inSeconds, 'the app is busy, still waiting for $what on $where');
        await Future<void>.delayed(_poll);
        continue;
      }
      final waited = DateTime.now().difference(start).inMilliseconds;
      if ((seen != null) != gone) {
        final secs = (waited / 1000).toStringAsFixed(1);
        return StructuredResponse(
          summary: gone ? '$where no longer shows $what after $secs s' : '$where shows $what after $secs s',
          data: {
            'app': where,
            'waitedMs': waited,
            if (seen != null) 'glintId': seen.glintId,
            if (seen != null) 'matchedText': seen.label,
          },
          nextSteps: [if (seen != null) 'act on it with glintId:"${seen.glintId}"'],
        );
      }
      if (waited >= timeoutMs) {
        return StructuredResponse.error(
          summary: gone
              ? '$where still shows $what after ${timeoutMs ~/ 1000} s'
              : '$where did not show $what within ${timeoutMs ~/ 1000} s',
          errorKind: GlintErrorKind.targetNeverReady,
          detail:
              visible.isEmpty ? 'the screen shows no text' : 'text on screen: ${visible.map((t) => '"$t"').join(', ')}',
          nextSteps: [
            'raise timeoutMs (max $_maxTimeoutMs) if the other side is slow',
            'get_scene app:"$where" to see what it shows instead',
          ],
        );
      }
      if (DateTime.now().difference(lastProgress) >= _progressEvery) {
        lastProgress = DateTime.now();
        progress?.call(waited ~/ 1000, 'waiting for $what on $where');
      }
      await Future<void>.delayed(_poll);
    }
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (sec, phase) =>
        notifier(ProgressNotification(progressToken: token, progress: sec, message: '$phase (${sec}s)'));
  }
}
