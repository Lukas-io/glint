import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
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
            'Swipe from one glintId to another. '
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
            'awaitReady': Schema.bool(
              description:
                  'Block until fromGlintId is in the scene and hittable, then fire.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for awaitReady. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'After the swipe, settle and return the new scene plus '
                  'changed (bool) and changeCategory. Default true.',
            ),
          },
          required: ['fromGlintId', 'toGlintId'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final from = args['fromGlintId']! as String;
    final to = args['toGlintId']! as String;
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;
    final returnScene = (args['returnScene'] as bool?) ?? true;

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
        final post = await readPostActionState(session, pre);
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
