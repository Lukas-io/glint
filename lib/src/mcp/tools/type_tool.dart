import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

class TypeTool extends GlintTool {
  const TypeTool();

  @override
  Tool get definition => Tool(
        name: 'type',
        description:
            'Type printable-ASCII text into the focused input field. '
            'If no field is focused, pass focus: <glintId> (a `>` typeable node '
            'from get_scene) to tap it first. '
            'With awaitReady: true on the focus field, blocks until it is hittable '
            'before tapping — use when the input may not be rendered yet. '
            'Returns structuredContent with: ok (bool), changed (bool), '
            'changeCategory. '
            'errorKind: unresolvedTarget (focus glintId not found), '
            'targetNeverReady (focus field never became hittable within ceilingMs).',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(description: 'Printable-ASCII text to type.'),
            'focus': Schema.string(
              description:
                  'Optional glintId of an input to tap before typing.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Only meaningful with `focus`: block until the focus target is hittable.',
            ),
            'readyTimeoutMs': Schema.int(
              description:
                  'Ceiling for `awaitReady` on the focus field. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'After typing, settle and return the new scene plus changed '
                  '(bool) and changeCategory. Default true.',
            ),
            'detail': Schema.bool(
              description:
                  'When true: include full geometry in structuredContent. Default false.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'When true: include the full rendered scene text as postScene. Default false.',
            ),
          },
          required: ['text'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final text = args['text']! as String;
    final focus = args['focus'] as String?;
    final t = readTargetedArgs(args, session.config);

    final pre = t.returnScene ? await snapshotPreAction(session) : null;

    final warnings = <String>[];
    ArmingReady? focusArming;

    if (focus != null) {
      final arming = await maybeAwaitReady(
        session: session,
        glintId: focus,
        awaitReady: t.awaitReady,
        ceilingMs: t.readyTimeoutMs,
        toolLabel: 'type:focus',
      );
      if (arming is ArmingFailed) return arming.envelope;
      if (arming is ArmingReady) focusArming = arming;

      final scene = await session.reader.readSummary();
      try {
        final focusResult = await session.interactor.run(
          scene,
          Tap(SymbolicTarget(focus)),
        );
        if (!focusResult.ok) {
          return StructuredResponse.error(
            summary: 'failed to focus $focus before typing',
            errorKind: focusResult.errorKind ?? GlintErrorKind.internal,
            detail: focusResult.error,
            nextSteps: focusResult.nextSteps,
          );
        }
        warnings.addAll(focusResult.warnings);
      } finally {
        await scene.dispose();
      }
    }

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(scene, TypeText(text));
      var response =
          StructuredResponse.fromActionResult(result, detail: t.detail)
              .addWarnings(warnings);
      if (focusArming != null) response = withArmedMetadata(response, focusArming);

      if (t.returnScene && !response.isError) {
        final post = await readPostActionState(session, pre,
            includeSceneText: t.fetchScene);
        if (post != null) {
          // A successful type always changes the field's value → contentChanged.
          // 'nothing' with no `focus` means the text landed nowhere — call it
          // out instead of reporting a silent success.
          final wentNowhere = post.changeCategory == 'nothing' && focus == null;
          response = response.mergeData(post.toData()).addWarnings([
            if (wentNowhere)
              'no field changed — is an input focused? pass '
                  'focus:<glintId> to tap one first',
          ]);
        }
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }
}
