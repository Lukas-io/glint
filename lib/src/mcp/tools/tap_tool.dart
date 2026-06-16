import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';

class TapTool extends GlintTool {
  const TapTool();

  @override
  Tool get definition => Tool(
        name: 'tap',
        description:
            'Tap a node by its glintId from get_scene. '
            'Returns structuredContent with: ok (bool), painted, hittable, '
            'physicalCenter, changed (bool), changeCategory (routeChanged/'
            'overlayAppeared/overlayDismissed/contentChanged/nothing). '
            'errorKind values: unresolvedTarget (glintId not found — re-run '
            'get_scene to get current ids), notHittable (covered by overlay/'
            'absorber — dismiss it first), backendToolError (native tap failed). '
            'With awaitReady: true: blocks until the target exists AND passes '
            'hit-test, then fires — use when targeting across screen transitions. '
            'ceilingMs controls the armed-intent timeout (default 5000).',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description:
                  'Stable id from `get_scene`, e.g. floating_action_button',
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
          required: ['glintId'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final glintId = args['glintId']! as String;
    final refuse = (args['refuseNotHittable'] as bool?) ?? false;
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;
    final returnScene = (args['returnScene'] as bool?) ?? true;
    final detail = (args['detail'] as bool?) ?? false;
    final fetchScene = (args['fetchScene'] as bool?) ?? false;

    // Pre-action snapshot (cheap) — only needed when returnScene is requested.
    final pre = returnScene ? await snapshotPreAction(session) : null;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: glintId,
      awaitReady: armed,
      ceilingMs: ceilingMs,
      toolLabel: 'tap',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final interactor = session.interactor..refuseNotHittable = refuse;
      final result = await interactor.run(scene, Tap(SymbolicTarget(glintId)));
      var response = StructuredResponse.fromActionResult(result, detail: detail);

      // Enrich unresolvedTarget with overlay context — helps agent understand
      // whether the scene changed (overlay appeared/dismissed) since last read.
      if (!result.ok &&
          result.errorKind == GlintErrorKind.unresolvedTarget &&
          scene.overlayRoots.isNotEmpty) {
        response = StructuredResponse.error(
          summary: response.summary,
          errorKind: GlintErrorKind.unresolvedTarget,
          detail: 'glintId "$glintId" not found in scene. '
              'A ${scene.hasBarrierOverlay ? "modal" : ""} overlay is currently '
              'active — the scene may have changed since your last get_scene. '
              'Re-read with get_scene to see current ids including overlay content.',
          nextSteps: const [
            'call get_scene to read the current overlay and base-screen ids',
          ],
        );
      }

      // Warn when tapping a base-screen node while a modal barrier is up —
      // the barrier absorbs the touch, so hittable:true can be misleading.
      if (result.ok &&
          scene.hasBarrierOverlay &&
          !scene.isInOverlay(glintId)) {
        response = StructuredResponse(
          summary: response.summary,
          warnings: [
            ...response.warnings,
            'a modal overlay is present; the tap may have landed on the barrier '
                'rather than your target — if the action had no effect, dismiss '
                'the dialog first and retry',
          ],
          nextSteps: response.nextSteps,
          isError: response.isError,
          data: response.data,
        );
      }

      // Post-action scene + changed signal (only when requested).
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

      return arming is ArmingReady
          ? withArmedMetadata(response, arming)
          : response;
    } finally {
      await scene.dispose();
    }
  }
}
