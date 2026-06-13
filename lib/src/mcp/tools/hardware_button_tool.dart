import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// iOS Xcode 26: `lock` works; others raise UnsupportedBackendAction
/// (see source-of-truth §13).
class HardwareButtonTool extends GlintTool {
  const HardwareButtonTool();

  @override
  Tool get definition => Tool(
        name: 'hardware_button',
        description:
            'Press a physical hardware button. iOS coverage is partial today '
            '(`lock` works on Xcode 26; `home` differs by device class — see project notes).',
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
        errorKind: 'InvalidArgument',
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
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
