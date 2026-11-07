import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../observability.dart' show CallProgress;
import '../../../perception.dart' show appBusyCause;
import '../../../semantic.dart' show Inert, SemanticScene;
import '../envelope.dart';
import '../session.dart';
import '../text_target.dart';
import '../tool.dart';
import '../tool_args.dart';

/// Blocks until an app shows (or stops showing) a text or glintId; with `app:` it watches another attached device, so one device can wait for what another caused.
class WaitForTool extends GlintTool {
  const WaitForTool();

  @override
  bool changesDevice(Map<String, Object?> args) => false;

  static const _defaultTimeoutMs = 15000;
  static const _maxTimeoutMs = 120000;
  static const _poll = Duration(milliseconds: 400);
  static const _progressEvery = Duration(seconds: 15);
  static const _wholeScreenShare = 0.7;

  @override
  Tool get definition => Tool(
        name: 'wait_for',
        description:
            'Wait until the app shows a text or glintId; with gone:true it waits for it to DISAPPEAR instead, so it keeps waiting while the text is on screen. On a match glintId is the matching node; tapTarget is the control around it to act on, left out when none or only a whole-screen wrapper surrounds it. With app:"<name>" it watches another attached app, so in a batch one device can wait for what another caused ("B shows Incoming call"). timeoutMs default 15000, max 120000; progress every 15 s. errorKind: targetNeverReady (timed out; detail lists the text on screen), invalidArgument, flutterModeRequired (device mode).',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(
              description: 'Visible text to wait for, matched as tap text: does (exact, then contains).',
            ),
            'glintId': Schema.string(description: 'Id to wait for instead of text.'),
            'gone': Schema.bool(description: 'Wait for the text or id to DISAPPEAR instead of appear. Default false.'),
            'timeoutMs': Schema.int(description: 'How long to wait, 100-120000. Default 15000.'),
          },
        ),
      );

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) =>
      GlintTool.ceilingFor(argInt(args, 'timeoutMs') ?? _defaultTimeoutMs);

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
    final goal = 'waiting for $what to ${gone ? 'disappear' : 'appear'} on $where';
    final progress = _progressSink(session, request);
    final start = DateTime.now();
    progress?.call(0, '$goal; timeout ${timeoutMs ~/ 1000} s');
    var lastProgress = start;
    var visible = const <String>[];
    while (true) {
      CallProgress.checkAlive();
      _Seen? seen;
      try {
        seen = await session.withScene((scene) async {
          visible = visibleLabels(scene);
          if (text != null) {
            final matches = textMatches(scene, text).where((m) => m.inert != Inert.hidden).toList();
            if (matches.isEmpty) return null;
            final m = matches.first;
            final own = m.nodeGlintId ?? m.glintId;
            final tapTarget = gone ? null : await _tapTarget(session, scene, own, m.glintId);
            return (glintId: own, label: m.label, tapTarget: tapTarget);
          }
          final node = scene.sourceScene.findByGlintId(glintId!);
          return node == null ? null : (glintId: glintId, label: node.textPreview ?? glintId, tapTarget: null);
        }, detail: SceneDetail.interactive);
      } on Object catch (e) {
        final busy = appBusyCause(e);
        if (busy == null) rethrow;
        final elapsed = DateTime.now().difference(start);
        if (elapsed.inMilliseconds >= timeoutMs) {
          return StructuredResponse.appBusy(busy.timeout, summary: '$where stayed busy while waiting for $what');
        }
        if (DateTime.now().difference(lastProgress) >= _progressEvery) {
          lastProgress = DateTime.now();
          progress?.call(elapsed.inSeconds, '$goal; the app is busy, still retrying after ${elapsed.inSeconds} s');
        }
        await Future<void>.delayed(_poll);
        continue;
      }
      final waited = DateTime.now().difference(start).inMilliseconds;
      if ((seen != null) != gone) {
        final secs = (waited / 1000).toStringAsFixed(1);
        final tapTarget = seen?.tapTarget;
        final actOn = tapTarget ?? (seen != null && text == null ? seen.glintId : null);
        return StructuredResponse(
          summary: gone ? '$where no longer shows $what after $secs s' : '$where shows $what after $secs s',
          data: {
            'app': where,
            'waitedMs': waited,
            if (seen != null) 'glintId': seen.glintId,
            if (seen != null) 'matchedText': seen.label,
            if (tapTarget != null && tapTarget != seen?.glintId) 'tapTarget': tapTarget,
          },
          nextSteps: [
            if (actOn != null) 'act on it with glintId:"$actOn"',
            if (seen != null && actOn == null)
              'get_scene to pick the control to act on; only a whole-screen wrapper surrounds it',
          ],
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
        final state = gone ? 'still on screen' : 'not on screen yet';
        progress?.call(waited ~/ 1000, '$goal; $state after ${waited ~/ 1000} s');
      }
      await Future<void>.delayed(_poll);
    }
  }

  /// The tappable control around the matched node, or null when it is the node itself, covers most of the screen, or cannot be measured.
  Future<String?> _tapTarget(GlintSession session, SemanticScene scene, String own, String target) async {
    if (target == own) return target;
    try {
      final c = await session.resolver.resolve(scene.sourceScene, target);
      final view = c.logicalViewSize.w * c.logicalViewSize.h;
      final area = c.logicalBounds.w * c.logicalBounds.h;
      if (view <= 0 || area / view >= _wholeScreenShare) return null;
      return target;
    } on Object {
      return null;
    }
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (sec, message) => notifier(ProgressNotification(progressToken: token, progress: sec, message: message));
  }
}

typedef _Seen = ({String glintId, String label, String? tapTarget});
