import 'dart:math' show max;

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
            'Type printable ASCII into the focused field. focus: <glintId> (a `>` node) taps it first; clear: true empties it first. errorKind: unresolvedTarget (focus id not found), targetNeverReady (focus field never hittable). Device mode: types into whatever has OS focus, with no change signal.',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(description: 'Printable-ASCII text to type.'),
            'keyDelayMs': Schema.int(
              description: 'Gap between keys, 0-1000 ms. Default 18. Raise it '
                  '(e.g. 80) when a formatted field (phone, card, amount) '
                  'drops characters.',
            ),
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
                  'With focus: wait until that field is hittable. Default false.',
            ),
            'readyTimeoutMs': Schema.int(
              description:
                  'Ceiling for awaitReady. Default 5000.',
            ),
            'returnScene': Schema.bool(
              description:
                  'Settle, then report changed and changeCategory. Default true.',
            ),
            'detail': Schema.bool(
              description:
                  'Include geometry (painted, hittable, physicalCenter). Default false.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'Also return the new scene text as postScene. Default false.',
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
    final clear = argBool(args, 'clear') ?? false;
    final keyDelayMs = argInt(args, 'keyDelayMs');
    if (keyDelayMs != null && (keyDelayMs < 0 || keyDelayMs > 1000)) {
      return StructuredResponse.error(
        summary: 'keyDelayMs must be between 0 and 1000',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['try keyDelayMs:80 for a field that drops characters'],
      );
    }
    final t = readTargetedArgs(args, session.config);
    if (session.isDeviceMode) {
      return _typeInDeviceMode(session, text, focus, clear, keyDelayMs);
    }

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
        if (!await _awaitReadyToType(session)) {
          warnings.add('$focus did not report focus within 2s after the tap; '
              'typed anyway');
        }
        // Android rebinds the keyboard to a newly focused field after the inset is already steady; keys sent in that gap are lost.
        if (session.device.platform == DevicePlatform.android) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }

      _ClearOutcome? cleared;
      if (clear) {
        cleared = await _clearField(session, scene);
        warnings.addAll(cleared.warnings);
      }

      final before = await _fieldInfo(session);
      var result = await session.interactor
          .run(scene, TypeText(text, keyDelayMs: keyDelayMs));
      var retyped = false;
      if (result.ok) {
        final first = await _check(session, before, text);
        if (first.problem != null && first.retryable) {
          await _clearField(session, scene);
          result = await session.interactor.run(
              scene, TypeText(text, keyDelayMs: max(keyDelayMs ?? 0, _retypeDelayMs)));
          retyped = true;
          final second = await _check(session, before, text);
          warnings.add(second.problem == null
              ? '${first.problem} on the first attempt; cleared it and retyped once at '
                  '${_retypeDelayMs}ms a key, and the field now holds exactly what was typed'
              : second.got == first.got
                  ? 'the field rewrites what is typed (it held ${first.got} chars both times, '
                      'for ${text.length} typed): the app formats this field, nothing was lost'
                  : '${second.problem} even after a slower retype; read the field and retype '
                      'the missing part, or ask the user to check the device');
        } else if (first.problem != null) {
          warnings.add('${first.problem}. Retype with clear:true and keyDelayMs:$_retypeDelayMs');
        }
      }
      var response =
          StructuredResponse.fromActionResult(result, detail: t.detail)
              .addWarnings(warnings);
      if (retyped) response = response.mergeData(const {'retyped': true});
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

  static const _retypeDelayMs = 40;

  Future<({String text, bool formatted})?> _fieldInfo(GlintSession session) async {
    try {
      return await session.focusedFieldInfo();
    } on Object {
      return null;
    }
  }

  /// Whether the focused field holds what was typed. A field without its own formatters must be [before] with [typed] inserted at one place; one with formatters only has to keep the typed letters and digits. Lengths only, so no password leaves the app.
  Future<({String? problem, bool retryable, int got})> _check(
      GlintSession session, ({String text, bool formatted})? before, String typed) async {
    final after = await _fieldInfo(session);
    if (before == null || after == null) return (problem: null, retryable: false, got: 0);
    final got = after.text.length;
    final exact = !before.formatted && !after.formatted && !typed.contains(RegExp('[\n\t]'));
    if (!exact) {
      String core(String v) => v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (core(after.text).contains(core(typed))) return (problem: null, retryable: false, got: got);
      return (
        problem: 'the field does not hold what was typed (${typed.length} chars typed, the field has $got): keys were dropped',
        retryable: false,
        got: got,
      );
    }
    if (holdsTyped(before.text, after.text, typed)) return (problem: null, retryable: false, got: got);
    final want = before.text.length + typed.length;
    final why = got > want
        ? 'keys repeated (a key held too long repeats, and iOS turns a repeated space into ". ")'
        : got < want
            ? 'keys were dropped'
            : 'different characters landed';
    return (
      problem: 'the field holds $got chars where $want were expected: $why',
      retryable: before.text.isEmpty,
      got: got,
    );
  }

  /// Device mode has no widget tree: focus cannot be resolved and there is no change signal, but the keys still land wherever the OS has focused. clear does a blind select-all + backspace first.
  Future<StructuredResponse> _typeInDeviceMode(
      GlintSession session, String text, String? focus, bool clear,
      int? keyDelayMs) async {
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
      await session.backend.typeText(text, keyDelayMs: keyDelayMs);
    } on IosToolchainBlocked catch (e) {
      return StructuredResponse.toolchainBlocked(e);
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

  /// Empties the focused field: select-all + backspace, then per-char backspace and forward delete when text remains. Reads the field before and after in flutter mode; device mode clears blind.
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
    // Backspace stops at the cursor, which a tap leaves mid-text; forward delete takes the rest.
    if (after != null && after.isNotEmpty) {
      await session.interactor
          .run(scene, PressKey(KeyName.delete, count: after.length));
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

  /// Keys sent before the tapped field takes focus are lost, and on Android `input text` also needs the soft keyboard fully shown; waits up to 2s for both.
  Future<bool> _awaitReadyToType(GlintSession session) async {
    final needsKeyboard = session.device.platform == DevicePlatform.android;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    double? lastInset;
    DateTime? focusedAt;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final focused = await session.focusedFieldText() != null;
        if (focused && !needsKeyboard) return true;
        if (focused) {
          focusedAt ??= DateTime.now();
          // The inset turns non-zero as the keyboard starts sliding in; it takes keys once it stops moving.
          final inset = (await session.uiState()).keyboardBottomPx;
          if (inset > 0 && inset == lastInset) return true;
          // No soft keyboard at all (a hardware keyboard is attached): focus is enough.
          if (inset == 0 &&
              DateTime.now().difference(focusedAt) >
                  const Duration(milliseconds: 600)) {
            return true;
          }
          lastInset = inset;
        }
      } on Object {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return false;
  }
}

/// Whether [after] is [before] with [typed] inserted at one place, once iOS smart quotes and dashes are undone.
bool holdsTyped(String before, String after, String typed) {
  String plain(String v) => v
      .replaceAll(RegExp('[\u2018\u2019]'), "'")
      .replaceAll(RegExp('[\u201C\u201D]'), '"')
      .replaceAll('\u2014', '--')
      .replaceAll('\u2013', '-');
  final b = plain(before), a = plain(after), t = plain(typed);
  if (a.length != b.length + t.length) return false;
  for (var i = 0; i <= b.length; i++) {
    if (a.substring(0, i) == b.substring(0, i) &&
        a.substring(i, i + t.length) == t &&
        a.substring(i + t.length) == b.substring(i)) {
      return true;
    }
  }
  return false;
}

/// What `type clear:true` did: an optional summary prefix, warnings, and data fields to merge.
class _ClearOutcome {
  _ClearOutcome({this.summaryPrefix, this.warnings = const [], this.data = const {}});
  final String? summaryPrefix;
  final List<String> warnings;
  final Map<String, Object?> data;
}
