import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

class TapTool extends GlintTool {
  const TapTool();

  @override
  Tool get definition => Tool(
        name: 'tap',
        description:
            'Tap a node by its glintId from get_scene, or pass x,y for raw '
            'coordinates (device mode: screenshot pixels; flutter mode: logical '
            'points). Returns changed + changeCategory (routeChanged / '
            'overlayAppeared / overlayDismissed / contentChanged / nothing) so '
            'you know if the screen reacted; pass detail:true for geometry. '
            'awaitReady:true blocks until the target exists AND is hittable '
            'before firing — use across screen transitions '
            '(readyTimeoutMs, default 5000).',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description:
                  'Stable id from `get_scene`, e.g. floating_action_button',
            ),
            'x': Schema.num(
              description:
                  'Raw x coordinate (with y). Device mode: screenshot pixels; '
                  'flutter mode: logical points. Bypasses glintId.',
            ),
            'y': Schema.num(
              description: 'Raw y coordinate (with x).',
            ),
            'refuseNotHittable': Schema.bool(
              description:
                  'When true, a non-hittable target produces an error (errorKind=notHittable) instead of a warning. Default false.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Arm the tap: block until the target is in the scene AND passes a hit test, then fire. Default false.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for `awaitReady`. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'After the tap, settle and return the new scene plus changed '
                  '(bool) and changeCategory. Collapses tap → wait_for_settle '
                  '→ get_scene into one call. Default true.',
            ),
            'detail': Schema.bool(
              description:
                  'When true: include full geometry (painted, hittable, physicalCenter) '
                  'in structuredContent. Default false (ok-only — saves tokens).',
            ),
            'fetchScene': Schema.bool(
              description:
                  'When true: include the full rendered scene text as postScene '
                  'in structuredContent. Collapses returnScene + get_scene into '
                  'one call. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final t = readTargetedArgs(args, session.config);

    // Coordinate tap — bypasses scene resolution; the only path in device mode.
    // In Flutter mode it still gets a changed-signal so raw x,y taps aren't
    // blind about whether anything happened.
    final pt = readPoint(args);
    if (pt != null) {
      return withCoordinateChange(
        session,
        () => coordinateTap(session, pt.x, pt.y),
        returnScene: t.returnScene,
        fetchScene: t.fetchScene,
      );
    }

    final glintId = args['glintId'] as String?;
    if (glintId == null) {
      return StructuredResponse.error(
        summary: 'tap needs either glintId or x + y',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const [
          'pass glintId from get_scene, or x,y coordinates',
        ],
      );
    }
    final refuse = (args['refuseNotHittable'] as bool?) ?? false;

    // Pre-action snapshot (cheap) — only needed when returnScene is requested.
    final pre = t.returnScene ? await snapshotPreAction(session) : null;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: glintId,
      awaitReady: t.awaitReady,
      ceilingMs: t.readyTimeoutMs,
      toolLabel: 'tap',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final interactor = session.interactor..refuseNotHittable = refuse;
      final result = await interactor.run(scene, Tap(SymbolicTarget(glintId)));
      var response =
          StructuredResponse.fromActionResult(result, detail: t.detail);
      if (arming is ArmingReady) response = withArmedMetadata(response, arming);

      if (!result.ok) {
        // Enrich unresolvedTarget with overlay context — the scene may have
        // changed (overlay appeared/dismissed) since the agent's last read.
        if (result.errorKind == GlintErrorKind.unresolvedTarget &&
            scene.overlayRoots.isNotEmpty) {
          response = StructuredResponse.error(
            summary: response.summary,
            errorKind: GlintErrorKind.unresolvedTarget,
            detail: 'glintId "$glintId" not found in scene. '
                'A ${scene.hasBarrierOverlay ? "modal" : ""} overlay is active — '
                'the scene may have changed since your last get_scene. '
                'Re-read with get_scene to see current ids including overlay content.',
            nextSteps: const [
              'call get_scene to read the current overlay and base-screen ids',
            ],
          );
        }
        return response;
      }

      // Warn when tapping a base-screen node while a modal barrier is up — the
      // barrier absorbs the touch, so hittable:true can be misleading.
      if (scene.hasBarrierOverlay && !scene.isInOverlay(glintId)) {
        response = response.addWarnings(const [
          'a modal overlay is present; the tap may have landed on the barrier '
              'rather than your target — if the action had no effect, dismiss '
              'the dialog first and retry',
        ]);
      }

      return appendPostAction(session, response, pre,
          returnScene: t.returnScene, fetchScene: t.fetchScene);
    } finally {
      await scene.dispose();
    }
  }
}
