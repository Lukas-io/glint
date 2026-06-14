import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Mechanically a swipe with a longer default hold so listeners recognise
/// it as drag rather than fling.
class DragTool extends GlintTool {
  const DragTool();

  @override
  Tool get definition => Tool(
        name: 'drag',
        description:
            'Drag from one glintId to another. `awaitReady` gates on the '
            '`from` endpoint.',
        inputSchema: ObjectSchema(
          properties: {
            'fromGlintId': Schema.string(),
            'toGlintId': Schema.string(),
            'durationMs': Schema.int(description: 'Hold time. Default 800.'),
            'awaitReady': Schema.bool(),
            'readyTimeoutMs': Schema.int(),
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
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs = (args['readyTimeoutMs'] as int?) ?? 5000;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: from,
      awaitReady: armed,
      ceilingMs: ceilingMs,
      toolLabel: 'drag',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to),
            durationMs: durationMs),
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
