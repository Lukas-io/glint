import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

class SwipeTool extends GlintTool {
  const SwipeTool();

  @override
  Tool get definition => Tool(
        name: 'swipe',
        description:
            'Swipe from one glintId to another, OR pass x1,y1,x2,y2 to swipe '
            'between raw coordinates (device mode: screenshot pixels; flutter '
            'mode: logical points) — coordinates bypass glintId resolution. '
            '`awaitReady` gates on the `from` endpoint — the `to` only needs '
            'to resolve, not be hittable. '
            'With returnScene: true (default), settles and returns the new scene '
            'plus changed + changeCategory.',
        inputSchema: ObjectSchema(
          properties: {
            'fromGlintId': Schema.string(
              description: 'Start point — stable id from get_scene.',
            ),
            'toGlintId': Schema.string(
              description: 'End point — stable id from get_scene.',
            ),
            'x1': Schema.num(description: 'Raw start x (with y1,x2,y2).'),
            'y1': Schema.num(description: 'Raw start y.'),
            'x2': Schema.num(description: 'Raw end x.'),
            'y2': Schema.num(description: 'Raw end y.'),
            'durationMs': Schema.int(
              description: 'Coordinate swipe duration. Default 300.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Block until fromGlintId is in the scene and hittable, then fire.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for awaitReady. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'After the swipe, settle and return changed (bool) and '
                  'changeCategory. Default true.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'When true: also include the full rendered scene text as '
                  'postScene. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final t = readTargetedArgs(args, session.config);

    // Coordinate swipe — bypasses scene resolution; the only path in device mode.
    final seg = readSegment(args);
    if (seg != null) {
      final durationMs = (args['durationMs'] as int?) ?? 300;
      return withCoordinateChange(
        session,
        () => coordinateSwipe(session, seg.x1, seg.y1, seg.x2, seg.y2, durationMs),
        returnScene: t.returnScene,
        fetchScene: t.fetchScene,
      );
    }

    final from = args['fromGlintId'] as String?;
    final to = args['toGlintId'] as String?;
    if (from == null || to == null) {
      return StructuredResponse.error(
        summary: 'swipe needs either fromGlintId + toGlintId, or x1,y1,x2,y2',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const [
          'pass fromGlintId + toGlintId (from get_scene), or all four of '
              'x1,y1,x2,y2',
        ],
      );
    }

    final pre = t.returnScene ? await snapshotPreAction(session) : null;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: from,
      awaitReady: t.awaitReady,
      ceilingMs: t.readyTimeoutMs,
      toolLabel: 'swipe',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to)),
      );
      var response = StructuredResponse.fromActionResult(result);
      if (arming is ArmingReady) response = withArmedMetadata(response, arming);
      return appendPostAction(session, response, pre,
          returnScene: t.returnScene, fetchScene: t.fetchScene);
    } finally {
      await scene.dispose();
    }
  }
}
