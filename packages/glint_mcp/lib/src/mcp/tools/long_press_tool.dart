import 'package:dart_mcp/server.dart';

import '../native_target.dart';
import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../text_target.dart';
import '../tool.dart';
import '../tool_args.dart';

class LongPressTool extends GlintTool {
  const LongPressTool();

  @override
  Tool get definition => Tool(
        name: 'long_press',
        description: 'Long-press a node by glintId or visible text, OR pass x,y for raw coordinates '
            '(device mode: screenshot pixels; flutter mode: logical points). '
            "Default duration 800ms, past Flutter's 500ms long-press threshold. "
            'Supports awaitReady / readyTimeoutMs to gate on the target '
            'becoming hittable before firing. '
            'With returnScene: true (default), settles and returns the new scene '
            'plus changed + changeCategory — useful for detecting context menus '
            'or sheets that appear after a long press.',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(
              description:
                  'Visible text of the target instead of glintId: a button label or text, exact match first, then contains. Dialogs are searched first. Several matches fail with the candidates.',
            ),
            'glintId': Schema.string(
              description: 'Stable id from get_scene.',
            ),
            'x': Schema.num(
                description:
                    'Raw x in logical points (device mode: screen pixels), with y. Off-screen points are refused. Bypasses glintId.'),
            'y': Schema.num(description: 'Raw y (with x), same unit.'),
            'durationMs': Schema.int(
              description: 'Hold time in ms. Default 800.',
            ),
            'awaitReady': Schema.bool(
              description: 'Wait until the target is on screen and hittable, then act. Default false.',
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
    final durationMs = argInt(args, 'durationMs') ?? 800;
    final t = readTargetedArgs(args, session.config);

    final pt = readPoint(args);
    if (pt != null) {
      final off = await rejectOffScreen(session, 'long_press', pointCoordinates(pt.x, pt.y));
      if (off != null) return off;
      return withCoordinateChange(
        session,
        () => coordinateLongPress(session, pt.x, pt.y, durationMs),
        returnScene: t.returnScene,
        fetchScene: t.fetchScene,
      );
    }

    final native =
        await resolveNativeTarget(session, glintId: args['glintId'] as String?, text: args['text'] as String?);
    if (native != null) {
      final hit = native.hit;
      if (hit == null) return native.error!;
      return withCoordinateChange(
        session,
        () => coordinateLongPress(session, hit.x, hit.y, durationMs, label: hit.label),
        returnScene: t.returnScene,
        fetchScene: t.fetchScene,
      );
    }

    final target = await readTarget(session, args, t, tool: 'long_press');
    if (target.error != null) return target.error!;
    final glintId = target.glintId!;

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
