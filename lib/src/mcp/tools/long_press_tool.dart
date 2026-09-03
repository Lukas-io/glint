import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

class LongPressTool extends GlintTool {
  const LongPressTool();

  @override
  Tool get definition => Tool(
        name: 'long_press',
        description:
            'Long-press a node by glintId, OR pass x,y for raw coordinates '
            '(device mode: screenshot pixels; flutter mode: logical points). '
            'Default duration 500ms. '
            'Supports awaitReady / readyTimeoutMs to gate on the target '
            'becoming hittable before firing. '
            'With returnScene: true (default), settles and returns the new scene '
            'plus changed + changeCategory — useful for detecting context menus '
            'or sheets that appear after a long press.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description: 'Stable id from get_scene.',
            ),
            'x': Schema.num(description: 'Raw x (with y). Bypasses glintId.'),
            'y': Schema.num(description: 'Raw y (with x).'),
            'durationMs': Schema.int(
              description: 'Hold time in ms. Default 500.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Block until the target is in the scene and hittable, then fire.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for awaitReady. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'After the press, settle and return changed (bool) and '
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
    final durationMs = (args['durationMs'] as int?) ?? 500;
    final t = readTargetedArgs(args, session.config);

    final pt = readPoint(args);
    if (pt != null) {
      return withCoordinateChange(
        session,
        () => coordinateLongPress(session, pt.x, pt.y, durationMs),
        returnScene: t.returnScene,
        fetchScene: t.fetchScene,
      );
    }

    final glintId = args['glintId'] as String?;
    if (glintId == null) {
      return StructuredResponse.error(
        summary: 'long_press needs either glintId or x + y',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const [
          'pass glintId from get_scene, or x,y coordinates',
        ],
      );
    }

    final arming = await maybeAwaitReady(
      session: session,
      glintId: glintId,
      awaitReady: t.awaitReady,
      ceilingMs: t.readyTimeoutMs,
      toolLabel: 'long_press',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final action = await openActionScene(session, snapshot: t.returnScene);
    final scene = action.scene;
    try {
      final result = await session.interactor.run(
        scene,
        LongPress(SymbolicTarget(glintId), durationMs: durationMs),
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
