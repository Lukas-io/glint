import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';

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

    // Coordinate swipe — bypasses scene resolution; the only path in device mode.
    final x1 = (args['x1'] as num?)?.toDouble();
    final y1 = (args['y1'] as num?)?.toDouble();
    final x2 = (args['x2'] as num?)?.toDouble();
    final y2 = (args['y2'] as num?)?.toDouble();
    if (x1 != null && y1 != null && x2 != null && y2 != null) {
      final durationMs = (args['durationMs'] as int?) ?? 300;
      return coordinateSwipe(session, x1, y1, x2, y2, durationMs);
    }

    final from = args['fromGlintId'] as String?;
    final to = args['toGlintId'] as String?;
    if (from == null || to == null) {
      return StructuredResponse.error(
        summary: 'swipe needs either fromGlintId + toGlintId, or x1,y1,x2,y2',
        errorKind: GlintErrorKind.invalidArgument,
      );
    }
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;
    final returnScene = (args['returnScene'] as bool?) ?? true;
    final fetchScene = (args['fetchScene'] as bool?) ?? false;

    final pre = returnScene ? await snapshotPreAction(session) : null;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: from,
      awaitReady: armed,
      ceilingMs: ceilingMs,
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
      if (returnScene && !response.isError) {
        final post = await readPostActionState(session, pre,
            includeSceneText: fetchScene);
        if (post != null) {
          response = StructuredResponse(
            summary: response.summary,
            warnings: response.warnings,
            nextSteps: response.nextSteps,
            isError: response.isError,
            data: {...?response.data, ...post.toData()},
          );
        }
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }
}
