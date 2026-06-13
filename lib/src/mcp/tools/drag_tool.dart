import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Drag is mechanically a swipe with a longer hold (so listeners that
/// distinguish flick vs drag see "drag"). Defaults to 800ms; pass
/// `durationMs` to override.
class DragTool extends GlintTool {
  const DragTool();

  @override
  Tool get definition => Tool(
        name: 'drag',
        description:
            'Drag from one glintId to another. Use for drag-and-drop and slow gestures '
            'that need the framework to recognise them as "drag" rather than "fling".',
        inputSchema: ObjectSchema(
          properties: {
            'fromGlintId': Schema.string(),
            'toGlintId': Schema.string(),
            'durationMs': Schema.int(
              description: 'Hold time in ms. Default 800.',
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
    final durationMs = (args['durationMs'] as int?) ?? 800;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(
          SymbolicTarget(from),
          SymbolicTarget(to),
          durationMs: durationMs,
        ),
      );
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
