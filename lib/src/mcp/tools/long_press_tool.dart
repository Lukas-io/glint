import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class LongPressTool extends GlintTool {
  const LongPressTool();

  @override
  Tool get definition => Tool(
        name: 'long_press',
        description: 'Long-press a node by glintId. Default duration 500ms. '
            'Supports `awaitReady` / `readyTimeoutMs` (§7.2 armed intent).',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(description: 'Stable id from `get_scene`.'),
            'durationMs': Schema.int(
                description: 'Hold time in ms. Default 500.'),
            'awaitReady': Schema.bool(),
            'readyTimeoutMs': Schema.int(),
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
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: glintId,
      awaitReady: armed,
      ceilingMs: ceilingMs,
      toolLabel: 'long_press',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        LongPress(SymbolicTarget(glintId), durationMs: durationMs),
      );
      final response = StructuredResponse.fromActionResult(result);
      return arming is ArmingReady
          ? withArmedMetadata(response, arming)
          : response;
    } finally {
      await scene.dispose();
    }
  }
}
