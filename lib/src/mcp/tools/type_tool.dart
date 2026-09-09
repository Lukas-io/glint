import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart' show Scene;
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
            'targetNeverReady (focus field never became hittable within ceilingMs). '
            'clear: true empties the focused field first (select-all + backspace). '
            'Device mode: types into whatever the OS has focused, with no '
            'change signal; focus: needs a Flutter app.',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(description: 'Printable-ASCII text to type.'),
            'clear': Schema.bool(
              description:
                  'Empty the focused field before typing (select-all + '
                  'backspace, then a per-char backspace fallback). Default false.',
            ),
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
    final clear = (args['clear'] as bool?) ?? false;
    final t = readTargetedArgs(args, session.config);
    if (session.isDeviceMode) return _typeInDeviceMode(session, text, focus, clear);

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
    }

    final action = await openActionScene(session, snapshot: t.returnScene);
    final scene = action.scene;
    final pre = action.pre;
    try {
      if (focus != null) {
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
      }

      _ClearOutcome? cleared;
      if (clear) {
        cleared = await _clearField(session, scene);
        warnings.addAll(cleared.warnings);
      }

      final result = await session.interactor.run(scene, TypeText(text));
      var response =
          StructuredResponse.fromActionResult(result, detail: t.detail)
              .addWarnings(warnings);
      if (cleared != null) {
        response = response.mergeData(cleared.data);
        if (cleared.summaryPrefix != null) {
          response =
              response.copyWith(summary: '${cleared.summaryPrefix}${response.summary}');
        }
      }
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
      await action.dispose();
    }
  }

  /// Device mode has no widget tree: focus cannot be resolved and there is no change signal, but the keys still land wherever the OS has focused. clear does a blind select-all + backspace first.
  Future<StructuredResponse> _typeInDeviceMode(
      GlintSession session, String text, String? focus, bool clear) async {
    if (focus != null) {
      return StructuredResponse.error(
        summary: 'focus:$focus needs a Flutter app; this session is in device mode',
        errorKind: GlintErrorKind.invalidArgument,
        detail: 'device mode has no widget tree to resolve a glintId against',
        nextSteps: const [
          'tap x,y on the field first (screenshot pixels), then type without focus',
        ],
      );
    }
    try {
      if (clear) {
        await session.backend.selectAll();
        await session.backend.pressKey(KeyName.backspace);
      }
      await session.backend.typeText(text);
    } on UnsupportedBackendAction catch (e) {
      return StructuredResponse.error(
        summary: '${session.backend.label}: typing not supported',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: e.detail,
      );
    } on Object catch (e) {
      return StructuredResponse.error(
        summary: 'typing failed in device mode',
        errorKind: GlintErrorKind.backendToolError,
        detail: '$e',
      );
    }
    return StructuredResponse(
      summary: '${clear ? "cleared blind, " : ""}typed ${text.length} chars '
          '(device mode: no change signal)',
      data: {'ok': true, 'mode': 'device', 'chars': text.length},
      nextSteps: const ['device op:screenshot to confirm the text landed'],
    );
  }

  /// Empties the focused field: select-all + backspace, then a per-char backspace fallback when text remains. Reads the field before and after in flutter mode; device mode clears blind.
  Future<_ClearOutcome> _clearField(GlintSession session, Scene scene) async {
    if (session.isDeviceMode) {
      try {
        await session.backend.selectAll();
        await session.backend.pressKey(KeyName.backspace);
      } on Object catch (e) {
        return _ClearOutcome(
          warnings: ['clear failed in device mode: $e'],
          data: const {'clearBlind': true},
        );
      }
      return _ClearOutcome(
        summaryPrefix: 'cleared blind (device mode), ',
        data: const {'clearBlind': true},
      );
    }
    final before = await session.focusedFieldText();
    await session.interactor.run(scene, const ClearField());
    var after = await session.focusedFieldText();
    if (after != null && after.isNotEmpty) {
      await session.interactor
          .run(scene, PressKey(KeyName.backspace, count: after.length));
      after = await session.focusedFieldText();
    }
    final removed = before?.length ?? 0;
    final remaining = after?.length ?? 0;
    return _ClearOutcome(
      summaryPrefix: before == null ? null : 'cleared $removed chars, ',
      warnings: [
        if (before == null)
          'no focused text field found to clear; cleared blind',
        if (remaining > 0) 'field still holds $remaining chars after clear',
      ],
      data: {
        if (before != null) 'cleared': removed,
        'remaining': remaining,
      },
    );
  }
}

/// What `type clear:true` did: an optional summary prefix, warnings, and data fields to merge.
class _ClearOutcome {
  _ClearOutcome({this.summaryPrefix, this.warnings = const [], this.data = const {}});
  final String? summaryPrefix;
  final List<String> warnings;
  final Map<String, Object?> data;
}
