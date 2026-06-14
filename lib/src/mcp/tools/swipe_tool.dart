import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class SwipeTool extends GlintTool {
  const SwipeTool();

  @override
  Tool get definition => Tool(
        name: 'swipe',
        description:
            'Swipe from one glintId to another. `awaitReady` gates on the '
            '`from` endpoint — the `to` only needs to resolve, not be hittable.',
        inputSchema: ObjectSchema(
          properties: {
            'fromGlintId': Schema.string(),
            'toGlintId': Schema.string(),
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
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: from,
      awaitReady: armed,
      ceilingMs: ceilingMs,
      toolLabel: 'swipe',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(SymbolicTarget(from), SymbolicTarget(to)),
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
