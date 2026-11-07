import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../observability.dart' show CallProgress, SceneState, StateObserver;
import '../../../perception.dart' show AppNotResumedError, InspectorReadError, appBusyCause;
import '../../../semantic.dart' show Inert, SemanticScene;
import '../envelope.dart';
import '../post_action.dart' show SceneSnapshot;
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
  static const _minTimeoutMs = 100;
  static const _maxTimeoutMs = 60000;
  static const _poll = Duration(milliseconds: 400);
  static const _settledAfter = Duration(seconds: 8);
  static const _wholeScreenShare = 0.7;

  @override
  Tool get definition => Tool(
        name: 'wait_for',
        description:
            'Wait until the app shows a text or glintId; with gone:true it waits for it to DISAPPEAR instead, so it keeps waiting while the text is on screen. On a match glintId is the matching node; tapTarget is the control around it to act on, left out when none or only a whole-screen wrapper surrounds it. With app:"<name>" it watches another attached app, so in a batch one device can wait for what another caused ("B shows Incoming call"). timeoutMs default 15000, max 60000 (a larger value is clamped and the reply says so); progress every 10 s names the condition and what the screen shows; a screen that moved to another route or got a dialog is named in the progress and the timeout detail. It fails early only when the app is suspended or behind a system surface (appNotResumed) or shows a build error (data.reason buildError). errorKind: targetNeverReady (data.reason timeout or buildError; detail says what the screen showed), appNotResumed, connectionLost, invalidArgument, flutterModeRequired (device mode).',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(
              description: 'Visible text to wait for, matched as tap text: does (exact, then contains).',
            ),
            'glintId': Schema.string(description: 'Id to wait for instead of text.'),
            'gone': Schema.bool(description: 'Wait for the text or id to DISAPPEAR instead of appear. Default false.'),
            'timeoutMs': Schema.int(description: 'How long to wait, 100-60000. Default 15000.'),
          },
        ),
      );

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) =>
      GlintTool.ceilingFor(_clampedTimeout(args).ms);

  static ({int ms, int? asked}) _clampedTimeout(Map<String, Object?> args) {
    final int? asked;
    try {
      asked = argInt(args, 'timeoutMs');
    } on ArgTypeError {
      return (ms: _defaultTimeoutMs, asked: null);
    }
    if (asked == null) return (ms: _defaultTimeoutMs, asked: null);
    final ms = asked.clamp(_minTimeoutMs, _maxTimeoutMs);
    return (ms: ms, asked: ms == asked ? null : asked);
  }

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    try {
      return await _wait(session, request);
    } finally {
      CallProgress.note(null);
    }
  }

  Future<StructuredResponse> _wait(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final text = args['text'] as String?;
    final glintId = args['glintId'] as String?;
    final gone = argBool(args, 'gone') ?? false;
    final timeout = _clampedTimeout(args);
    final timeoutMs = timeout.ms;
    final clampNote = [
      if (timeout.asked != null)
        'timeoutMs ${timeout.asked} is ${timeout.asked! < _minTimeoutMs ? 'below the minimum of $_minTimeoutMs' : 'above the cap of $_maxTimeoutMs'}; waited at most $timeoutMs ms',
    ];
    if ((text == null) == (glintId == null)) {
      return StructuredResponse.error(
        summary: 'wait_for takes exactly one of text or glintId',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass text:"Incoming call" or glintId:"<id>"'],
      );
    }

    final what = text != null ? '"$text"' : glintId!;
    final where = session.active?.label ?? 'the app';
    final goal = 'waiting for $what to ${gone ? 'disappear' : 'appear'} on $where';
    final start = DateTime.now();
    CallProgress.note('$goal; timeout ${timeoutMs ~/ 1000} s');
    _Look? look;
    _Look? first;
    String? moved;
    var changedAt = start;
    _Look? previous;
    while (true) {
      CallProgress.checkAlive();
      final _Read read;
      try {
        read = await session.withScene((scene) async {
          final snap = SceneSnapshot.from(scene);
          final state = const StateObserver().observe(scene);
          final visible = visibleLabels(scene);
          final look = _Look(
            route: snap.routeName,
            dialog: snap.hasOverlay,
            hash: snap.contentHash,
            state: state,
            texts: visible,
          );
          if (text != null) {
            final matches = textMatches(scene, text).where((m) => m.inert != Inert.hidden).toList();
            if (matches.isEmpty) return (seen: null, look: look);
            final m = matches.first;
            final own = m.nodeGlintId ?? m.glintId;
            final tapTarget = gone ? null : await _tapTarget(session, scene, own, m.glintId);
            return (seen: (glintId: own, label: m.label, tapTarget: tapTarget), look: look);
          }
          final node = scene.sourceScene.findByGlintId(glintId!);
          final seen = node == null ? null : (glintId: glintId, label: node.textPreview ?? glintId, tapTarget: null);
          return (seen: seen, look: look);
        }, detail: SceneDetail.interactive);
      } on Object catch (e) {
        final busy = appBusyCause(e);
        if (busy == null) {
          if (e is! InspectorReadError ||
              looksLikeConnectionLoss(e) ||
              GlintTool.pausedAtBreakpoint(session, e) != null) {
            rethrow;
          }
          final lifecycle = e is AppNotResumedError ? e.lifecycle : await _lifecycle(session);
          if (lifecycle != null && lifecycle != 'resumed') {
            final reply = await noFrameResponse(session, e);
            return reply.mergeData({
              'reason': 'appNotResumed',
              'detail':
                  '${reply.data?['detail']}; ${look == null ? 'no read completed before it went away' : 'last seen: ${look.describe()}'}',
            }).addWarnings(clampNote);
          }
          final waited = DateTime.now().difference(start);
          if (waited.inMilliseconds >= timeoutMs) {
            return StructuredResponse.error(
              summary: '$where did not show $what within ${timeoutMs ~/ 1000} s',
              errorKind: GlintErrorKind.targetNeverReady,
              detail: 'the app is running but had no readable widget tree for the whole wait: $e',
              nextSteps: const [
                'get_scene shows whether the app has drawn its first frame',
                'retry once the app is up',
              ],
            ).mergeData({'reason': 'timeout', 'waitedMs': waited.inMilliseconds}).addWarnings(clampNote);
          }
          CallProgress.note('$goal; the app has no widget tree yet, still waiting after ${waited.inSeconds} s');
          await Future<void>.delayed(_poll);
          continue;
        }
        final elapsed = DateTime.now().difference(start);
        if (elapsed.inMilliseconds >= timeoutMs) {
          return StructuredResponse.appBusy(busy.timeout, summary: '$where stayed busy while waiting for $what')
              .addWarnings(clampNote);
        }
        CallProgress.note('$goal; the app is busy, still retrying after ${elapsed.inSeconds} s');
        await Future<void>.delayed(_poll);
        continue;
      }
      final seen = read.seen;
      final now = read.look;
      look = now;
      first ??= now;
      if (previous == null || !now.sameScreen(previous)) changedAt = DateTime.now();
      previous = now;
      moved ??= now.movedFrom(first, DateTime.now().difference(start));
      final waited = DateTime.now().difference(start).inMilliseconds;
      if ((seen != null) != gone) {
        final secs = (waited / 1000).toStringAsFixed(1);
        final tapTarget = seen?.tapTarget;
        final actOn = tapTarget ?? (seen != null && text == null ? seen.glintId : null);
        return StructuredResponse(
          summary: gone ? '$where no longer shows $what after $secs s' : '$where shows $what after $secs s',
          warnings: clampNote,
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
      final unchangedFor = DateTime.now().difference(changedAt);
      if (!gone && unchangedFor >= _settledAfter && now.state == SceneState.error) {
        return _failure(
          summary: '$where did not show $what: the screen shows a build error and has not changed for '
              '${unchangedFor.inSeconds} s',
          reason: 'buildError',
          look: now,
          waitedMs: waited,
          unchangedFor: unchangedFor,
          moved: moved,
          clampNote: clampNote,
          nextSteps: const [
            'get_scene shows the error; the app needs a fix or a hot restart before this text can appear'
          ],
        );
      }
      if (waited >= timeoutMs) {
        return _failure(
          summary: gone
              ? '$where still shows $what after ${timeoutMs ~/ 1000} s'
              : '$where did not show $what within ${timeoutMs ~/ 1000} s',
          reason: 'timeout',
          look: now,
          waitedMs: waited,
          unchangedFor: unchangedFor,
          moved: moved,
          clampNote: clampNote,
          nextSteps: [
            if (timeoutMs < _maxTimeoutMs) 'raise timeoutMs (max $_maxTimeoutMs) if the other side is slow',
            if (moved != null)
              'get_scene shows where the app went; go back or act there if that is where the flow ended up',
            'get_scene app:"$where" to see what it shows instead',
          ],
        );
      }
      CallProgress.note(
        '$goal; ${gone ? 'still on screen' : 'not on screen yet'} after ${waited ~/ 1000} of ${timeoutMs ~/ 1000} s; '
        'last seen: ${now.describe()}${moved == null ? '' : '; $moved'}',
      );
      await Future<void>.delayed(_poll);
    }
  }

  Future<String?> _lifecycle(GlintSession session) async {
    try {
      return await session.lifecycleState();
    } on Object {
      return null;
    }
  }

  StructuredResponse _failure({
    required String summary,
    required String reason,
    required _Look look,
    required int waitedMs,
    required Duration unchangedFor,
    required String? moved,
    required List<String> clampNote,
    required List<String> nextSteps,
  }) =>
      StructuredResponse.error(
        summary: summary,
        errorKind: GlintErrorKind.targetNeverReady,
        detail: 'last seen after ${(waitedMs / 1000).toStringAsFixed(1)} s: ${look.describe()}'
            '${moved == null ? '' : '; it $moved and has not changed for ${unchangedFor.inSeconds} s'}',
        nextSteps: nextSteps,
      ).mergeData({
        'reason': reason,
        'waitedMs': waitedMs,
        'unchangedMs': unchangedFor.inMilliseconds,
        'route': look.route,
        'dialog': look.dialog,
        'state': look.state.name,
        'texts': look.texts,
      }).addWarnings(clampNote);

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
}

typedef _Seen = ({String glintId, String label, String? tapTarget});

typedef _Read = ({_Seen? seen, _Look look});

/// What one poll saw of the screen, for progress lines, the settled check and the failure detail.
class _Look {
  const _Look({
    this.route = '',
    this.dialog = false,
    this.hash = 0,
    this.state = SceneState.loaded,
    this.texts = const [],
  });

  final String route;
  final bool dialog;
  final int hash;
  final SceneState state;
  final List<String> texts;

  String get routeLabel => route.isEmpty ? 'an unnamed route' : 'route "$route"';

  /// How this look differs from [first] in front of the screen the wait began on, or null when it does not.
  String? movedFrom(_Look first, Duration after) {
    final at = '${after.inSeconds} s into the wait';
    if (route != first.route) return 'moved to $routeLabel $at';
    if (dialog && !first.dialog) return 'got a dialog in front $at';
    return null;
  }

  bool sameScreen(_Look other) => route == other.route && dialog == other.dialog && hash == other.hash;

  String describe() => [
        if (route.isNotEmpty) 'route "$route"',
        if (dialog) 'a dialog is up',
        if (state != SceneState.loaded) 'state ${state.name}',
        texts.isEmpty ? 'no text' : 'text ${texts.take(8).map((t) => '"$t"').join(', ')}',
      ].join(', ');
}
