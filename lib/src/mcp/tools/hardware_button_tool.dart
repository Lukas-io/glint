import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

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
            'home (Face ID gesture) all work on Xcode 26. Others are '
            'platform-dependent; check capabilities.',
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

    final button = HardwareButton.values
        .where((b) => b.name == name)
        .firstOrNull;
    if (button == null) {
      return StructuredResponse.error(
        summary: 'unknown hardware button: $name',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: [
          'use one of: ${HardwareButton.values.map((b) => b.name).join(', ')}'
        ],
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
        return StructuredResponse(
          summary: response.summary,
          warnings: response.warnings,
          data: response.data,
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
