import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';

/// Mechanically a swipe with a longer default hold so listeners recognise
/// it as drag rather than fling.
class DragTool extends GlintTool {
  const DragTool();

  @override
  Tool get definition => Tool(
        name: 'drag',
        description:
            'Drag from one glintId to another — same as swipe but with a '
            'longer hold (800ms default) so the framework recognises it as '
            'a drag gesture rather than a fling. '
            '`awaitReady` gates on the `from` endpoint. '
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
            'durationMs': Schema.int(
              description: 'Hold time in ms. Default 800.',
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
                  'After the drag, settle and return changed (bool) and '
                  'changeCategory. Default true.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'When true: also include the full rendered scene text as '
                  'postScene. Default false.',
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
    final durationMs = (args['durationMs'] as int?) ?? 800;
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
      toolLabel: 'drag',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to),
            durationMs: durationMs),
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
