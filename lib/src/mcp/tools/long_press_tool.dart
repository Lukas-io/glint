import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class LongPressTool extends GlintTool {
  const LongPressTool();

  @override
  Tool get definition => Tool(
        name: 'long_press',
        description:
            'Long-press a node by glintId. Default duration 500ms.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description: 'Stable id from `get_scene`.',
            ),
            'durationMs': Schema.int(
              description: 'Hold time in ms. Default 500.',
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
    final durationMs = (args['durationMs'] as int?) ?? 500;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        LongPress(SymbolicTarget(glintId), durationMs: durationMs),
      );
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
