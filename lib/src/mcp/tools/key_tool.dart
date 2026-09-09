import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// The editing keys and a change signal follow a press, so an agent can clear a
/// field, submit a form, or move the caret without a printable character.
class KeyTool extends GlintTool {
  const KeyTool();

  static const _editingKeys = {
    KeyName.backspace,
    KeyName.delete,
    KeyName.enter,
    KeyName.tab,
    KeyName.space,
  };

  @override
  Tool get definition => Tool(
        name: 'key',
        description:
            'Press a non-printing key: backspace, delete, enter, tab, escape, '
            'space, up, down, left, right. count repeats it (1-50); modifiers '
            'holds cmd / shift / ctrl / alt around it. Sends to the focused '
            'field, so focus one first (type focus:<id> or tap it). Returns '
            'changed / changeCategory like type. To empty a field use '
            'type clear:true. errorKind: invalidArgument (bad key / count / '
            'modifier), flutterModeRequired (device mode has no scene), '
            'unsupportedBackendAction (backend has no keyboard).',
        inputSchema: ObjectSchema(
          properties: {
            'key': Schema.string(
              description:
                  'One of: ${KeyName.values.map((k) => k.name).join(', ')}.',
            ),
            'count': Schema.int(description: 'Times to press it (1-50). Default 1.'),
            'modifiers': Schema.list(
              items: Schema.string(),
              description:
                  'Held around the key: ${KeyModifier.values.map((m) => m.name).join(', ')}.',
            ),
            'returnScene': Schema.bool(
              description: 'Read the post-press scene for changed. Default true.',
            ),
          },
          required: ['key'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final key = enumByName(KeyName.values, args['key'] as String?);
    if (key == null) {
      return StructuredResponse.error(
        summary: 'unknown key: ${args['key']}',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: ['use one of: ${KeyName.values.map((k) => k.name).join(', ')}'],
      );
    }
    final count = (args['count'] as int?) ?? 1;
    if (count < 1 || count > 50) {
      return StructuredResponse.error(
        summary: 'count $count out of range',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass count between 1 and 50'],
      );
    }
    final modifiers = <KeyModifier>{};
    for (final raw in (args['modifiers'] as List?) ?? const []) {
      final m = enumByName(KeyModifier.values, raw as String?);
      if (m == null) {
        return StructuredResponse.error(
          summary: 'unknown modifier: $raw',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: [
            'use any of: ${KeyModifier.values.map((m) => m.name).join(', ')}'
          ],
        );
      }
      modifiers.add(m);
    }

    final t = readTargetedArgs(args, session.config);

    if (session.isDeviceMode) {
      if (!session.backend.capabilities.keys) {
        return StructuredResponse.error(
          summary: '${session.backend.label}: no keyboard on this backend',
          errorKind: GlintErrorKind.unsupportedBackendAction,
        );
      }
      try {
        await session.backend
            .pressKey(key, count: count, modifiers: modifiers);
      } on UnsupportedBackendAction catch (e) {
        return StructuredResponse.error(
          summary: '${session.backend.label}: key not supported',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: e.detail,
        );
      } on Object catch (e) {
        return StructuredResponse.error(
          summary: 'key ${key.name} failed in device mode',
          errorKind: GlintErrorKind.backendToolError,
          detail: '$e',
        );
      }
      return StructuredResponse(
        summary: 'pressed ${key.name}${count > 1 ? ' x$count' : ''} '
            '(device mode: no change signal)',
        data: {'ok': true, 'mode': 'device', 'key': key.name, 'count': count},
      );
    }

    final action = await openActionScene(session, snapshot: t.returnScene);
    try {
      final result = await session.interactor
          .run(action.scene, PressKey(key, count: count, modifiers: modifiers));
      var response =
          StructuredResponse.fromActionResult(result, detail: t.detail);
      response = await appendPostAction(session, response, action.pre,
          returnScene: t.returnScene, fetchScene: t.fetchScene);
      if (!response.isError && response.data?['changed'] == false) {
        if (_editingKeys.contains(key)) {
          response = response.addWarnings([
            'the ${key.name} key changed nothing — is a text field focused? '
                'type focus:<id> or tap a `>` node first',
          ]);
        } else {
          response = response.addWarnings([
            'a caret move is not visible to the change detector; '
                'get_scene to confirm the field state',
          ]);
        }
      }
      return response;
    } finally {
      await action.dispose();
    }
  }
}
