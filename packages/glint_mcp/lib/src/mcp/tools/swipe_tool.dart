import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../segment_swipe.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

class SwipeTool extends GlintTool {
  const SwipeTool();

  @override
  Tool get definition => Tool(
        name: 'swipe',
        description: 'Swipe from one glintId to another, OR pass x1,y1,x2,y2 to swipe '
            'between raw coordinates (device mode: screenshot pixels; flutter '
            'mode: logical points, as in every reply; points off the screen are '
            'refused); coordinates bypass glintId resolution. '
            '`awaitReady` gates on the `from` endpoint — the `to` only needs '
            'to resolve, not be hittable. '
            'With returnScene: true (default), settles and returns the new scene '
            'plus changed + changeCategory.',
        inputSchema: ObjectSchema(
          properties: {
            'edge': Schema.string(
              description: 'A system gesture from a screen edge instead of a swipe: left (back), bottom (home), '
                  'bottomHold (app switcher), topLeft (Notification Center), topRight (Control Center). Physical iPhone.',
            ),
            'fromGlintId': Schema.string(
              description: 'Start point — stable id from get_scene.',
            ),
            'toGlintId': Schema.string(
              description: 'End point — stable id from get_scene.',
            ),
            'x1': Schema.num(description: 'Start x in logical points (device mode: screen pixels), with y1,x2,y2.'),
            'y1': Schema.num(description: 'Start y, same unit.'),
            'x2': Schema.num(description: 'End x, same unit.'),
            'y2': Schema.num(description: 'End y, same unit.'),
            'durationMs': Schema.int(
              description: 'Coordinate swipe duration. Default 300.',
            ),
            'awaitReady': Schema.bool(
              description: 'Wait until fromGlintId is on screen and hittable, then act. Default false.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for awaitReady. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description: 'Settle, then report changed and changeCategory. Default true.',
            ),
            'fetchScene': Schema.bool(
              description: 'Also return the new scene text as postScene. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final edgeName = args['edge'] as String?;
    if (edgeName != null) {
      final edge = ScreenEdge.values.where((e) => e.name == edgeName).firstOrNull;
      if (edge == null) {
        return StructuredResponse.error(
          summary: 'unknown edge: $edgeName',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: [for (final e in ScreenEdge.values) 'edge:"${e.name}"'],
        );
      }
      return withCoordinateChange(session, () async {
        try {
          await session.backend.edgeSwipe(edge);
        } on Object catch (e) {
          return StructuredResponse.backendError('edge swipe ${edge.name} was not delivered', e);
        }
        final input = session.backend.takeInput();
        return StructuredResponse(
          summary: 'swiped from the ${edge.name} edge${input == null ? '' : ' · ${input.label}'}',
          data: {'ok': true, 'edge': edge.name, if (input != null) 'input': input.toJson()},
        );
      });
    }
    final t = readTargetedArgs(args, session.config);

    // Coordinate swipe — bypasses scene resolution; the only path in device mode.
    final seg = readSegment(args);
    if (seg != null) {
      final durationMs = argInt(args, 'durationMs') ?? 300;
      return segmentSwipe(session, 'swipe', seg, durationMs,
          verb: 'swiped', returnScene: t.returnScene, fetchScene: t.fetchScene);
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

    final arming = await maybeAwaitReady(
      session: session,
      glintId: from,
      awaitReady: t.awaitReady,
      ceilingMs: t.readyTimeoutMs,
      toolLabel: 'swipe',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final action = await openActionScene(session, snapshot: t.returnScene);
    final scene = action.scene;
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to)),
      );
      var response = StructuredResponse.fromActionResult(result);
      if (arming is ArmingReady) response = withArmedMetadata(response, arming);
      return await appendPostAction(session, response, action.pre,
          returnScene: t.returnScene, fetchScene: t.fetchScene);
    } finally {
      await action.dispose();
    }
  }
}
