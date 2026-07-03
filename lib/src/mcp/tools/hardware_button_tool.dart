import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// iOS Xcode 26: lock + unlock + home all wired. Others
/// (back, volumeUp/Down, appSwitcher) raise UnsupportedBackendAction.
/// See source-of-truth §13.
class HardwareButtonTool extends GlintTool {
  const HardwareButtonTool();

  @override
  Tool get definition => Tool(
        name: 'hardware_button',
        description:
            'Press a physical hardware button. iOS Sim: lock + unlock '
            '(Face ID auth via Darwin notification + bottom-edge swipe) + '
            'home (Face ID gesture) all work on Xcode 26. Returns the app '
            'lifecycle after the press (resumed / inactive / paused) so you know '
            'it took. Available buttons are listed in attach\'s reply.',
        inputSchema: ObjectSchema(
          properties: {
            'button': Schema.string(
              description:
                  'Button name. One of: ${HardwareButton.values.map((b) => b.name).join(', ')}.',
            ),
          },
          required: ['button'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = args['button']! as String;

    final button = enumByName(HardwareButton.values, name);
    if (button == null) {
      return StructuredResponse.error(
        summary: 'unknown hardware button: $name',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: [
          'use one of: ${HardwareButton.values.map((b) => b.name).join(', ')}'
        ],
      );
    }

    // Device mode: hardware buttons are OS-level — go straight to the backend
    // (no Flutter scene / interactor available).
    if (session.isDeviceMode) {
      try {
        await session.backend.pressHardwareButton(button);
      } on UnsupportedBackendAction catch (e) {
        return StructuredResponse.error(
          summary: '${session.backend.label}: ${button.name} not supported',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: e.detail,
        );
      } on Object catch (e) {
        return StructuredResponse.error(
          summary: 'hardware button ${button.name} failed',
          errorKind: GlintErrorKind.backendToolError,
          detail: '$e',
        );
      }
      return StructuredResponse(
        summary: 'pressed ${button.name}',
        data: {'ok': true, 'mode': 'device'},
      );
    }

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        PressHardwareButton(button),
      );
      final response = StructuredResponse.fromActionResult(result);
      if (!response.isError) {
        // The "what happened" for a hardware button is a lifecycle change, not
        // a scene diff. Read it best-effort (home may background the app and
        // make the eval fail — that itself signals it took).
        String? lifecycle;
        try {
          lifecycle = await session.lifecycleState();
        } on Object {
          // app backgrounded / VM unreachable — leave lifecycle null
        }
        return response.copyWith(
          summary: lifecycle != null
              ? '${response.summary} — app is $lifecycle'
              : response.summary,
          data: {...?response.data, if (lifecycle != null) 'lifecycle': lifecycle},
          nextSteps: [
            if (button == HardwareButton.unlock)
              'call get_scene to read the screen after unlock'
            else if (button == HardwareButton.home)
              'the app is now backgrounded — reopen it then call get_scene'
            else if (button == HardwareButton.lock)
              'device is locked — call hardware_button with unlock to resume',
          ],
        );
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }
}
