import '../../interaction.dart';
import '../../perception.dart';
import 'envelope.dart';
import 'post_action.dart';
import 'session.dart';
import 'tool_args.dart';

/// Most taps one sequence may carry.
const maxSequenceTaps = 50;

/// One sequence step: a glintId, or x,y in the tool's coordinate space.
typedef SequenceStep = ({String? glintId, double? x, double? y});

/// Parses `sequence` into steps, or returns the invalidArgument envelope that names the bad step.
({List<SequenceStep>? steps, StructuredResponse? error}) parseTapSequence(
    Object? raw) {
  StructuredResponse bad(String why) => StructuredResponse.error(
        summary: 'sequence: $why',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const [
          'pass sequence:[{glintId:"key_1"}, {x:120, y:640}, …] '
              '(1-$maxSequenceTaps steps)',
        ],
      );
  if (raw is! List || raw.isEmpty) return (steps: null, error: bad('needs 1 or more steps'));
  if (raw.length > maxSequenceTaps) {
    return (steps: null, error: bad('${raw.length} steps; the limit is $maxSequenceTaps'));
  }
  final steps = <SequenceStep>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) return (steps: null, error: bad('step ${i + 1} is not an object'));
    final m = item.cast<String, Object?>();
    final id = m['glintId'];
    final double? x;
    final double? y;
    try {
      x = argNum(m, 'x');
      y = argNum(m, 'y');
    } on ArgTypeError catch (e) {
      return (steps: null, error: bad('step ${i + 1}: $e'));
    }
    if (id is String && id.isNotEmpty) {
      steps.add((glintId: id, x: null, y: null));
    } else if (x != null && y != null) {
      steps.add((glintId: null, x: x, y: y));
    } else {
      return (steps: null, error: bad('step ${i + 1} needs glintId or x + y'));
    }
  }
  return (steps: steps, error: null);
}

/// Resolves every glintId against one scene read, then fires the taps back to back with [intervalMs] between them and reads the outcome once.
Future<StructuredResponse> runTapSequence(
  GlintSession session,
  List<SequenceStep> steps, {
  required int intervalMs,
  required bool returnScene,
  required bool fetchScene,
}) async {
  final needsScene = steps.any((s) => s.glintId != null);
  if (needsScene && session.isDeviceMode) {
    return StructuredResponse.error(
      summary: 'sequence uses glintIds, but device mode has no widget tree',
      errorKind: GlintErrorKind.invalidArgument,
      nextSteps: const ['use x,y steps (screenshot pixels) in device mode'],
    );
  }
  final wantsChange = returnScene && !session.isDeviceMode;
  final action = needsScene || wantsChange
      ? await openActionScene(session, snapshot: wantsChange)
      : null;
  try {
    final points = <({double x, double y})>[];
    final warnings = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.glintId == null) {
        points.add((x: s.x!, y: s.y!));
        continue;
      }
      final scene = action!.scene;
      if (scene.findByGlintId(s.glintId!) == null) {
        return StructuredResponse.error(
          summary: 'sequence step ${i + 1}: no node with glintId "${s.glintId}"; nothing was tapped',
          errorKind: GlintErrorKind.unresolvedTarget,
          nextSteps: [
            if (didYouMean(suggestIds(scene.glintIds, s.glintId!)) case final hint?) hint,
            'call get_scene for the current ids',
          ],
        );
      }
      final c = await session.resolver.resolve(scene, s.glintId!);
      if (!c.hittable) warnings.add('step ${i + 1} (${s.glintId}) is not hittable');
      points.add(c.logicalCenter);
    }
    final dpr = session.device.devicePixelRatio;
    final started = DateTime.now();
    try {
      await session.backend.tapSequence([
        for (final p in points) (x: (p.x * dpr).round(), y: (p.y * dpr).round()),
      ], intervalMs: intervalMs);
    } on Object catch (e) {
      return StructuredResponse.error(
        summary: 'tap sequence of ${points.length} failed',
        errorKind: GlintErrorKind.backendToolError,
        detail: '$e',
        nextSteps: const [
          'some taps may have landed: re-read the screen before retrying',
        ],
      );
    }
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    var response = StructuredResponse(
      summary: 'tapped ${points.length} steps in ${elapsed}ms',
      warnings: warnings,
      data: {
        'ok': true,
        'taps': points.length,
        'elapsedMs': elapsed,
        if (session.isDeviceMode) 'mode': 'device',
      },
    );
    if (wantsChange) {
      response = await appendPostAction(session, response, action!.pre,
          returnScene: true, fetchScene: fetchScene);
    }
    return response;
  } finally {
    await action?.dispose();
  }
}
