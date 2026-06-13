import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class SwipeTool extends GlintTool {
  const SwipeTool();

  @override
  Tool get definition => Tool(
        name: 'swipe',
        description:
            'Swipe from one glintId to another. Useful for scrolling (swipe from a row near '
            'the bottom toward a row near the top) and drag-and-drop.',
        inputSchema: ObjectSchema(
          properties: {
            'fromGlintId': Schema.string(
              description: 'Starting point — a glintId from `get_scene`.',
            ),
            'toGlintId': Schema.string(
              description: 'End point — a glintId from `get_scene`.',
            ),
          },
          required: ['fromGlintId', 'toGlintId'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final from = args['fromGlintId']! as String;
    final to = args['toGlintId']! as String;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to)),
      );
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
