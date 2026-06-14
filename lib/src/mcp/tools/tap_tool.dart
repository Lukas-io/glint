import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class TapTool extends GlintTool {
  const TapTool();

  @override
  Tool get definition => Tool(
        name: 'tap',
        description:
            'Tap a node by its glintId. With `awaitReady: true`, blocks '
            'until the target exists AND is hittable, then fires '
            '(§7.2 armed intent). Catch is structured: `targetNeverReady` '
            'if it never becomes hittable within `readyTimeoutMs`.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description:
                  'Stable id from `get_scene`, e.g. floating_action_button',
            ),
            'refuseNotHittable': Schema.bool(
              description:
                  'When true, a non-hittable target produces an error (errorKind=notHittable) instead of a warning. Default false.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Arm the tap: block until the target is in the scene AND passes a hit test, then fire. Default false.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for `awaitReady`. Default 5000.',
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
    final refuse = (args['refuseNotHittable'] as bool?) ?? false;
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs =
        (args['readyTimeoutMs'] as int?) ?? session.config.readyTimeoutMs;

    final arming = await maybeAwaitReady(
      session: session,
      glintId: glintId,
      awaitReady: armed,
      ceilingMs: ceilingMs,
      toolLabel: 'tap',
    );
    if (arming is ArmingFailed) return arming.envelope;

    final scene = await session.reader.readSummary();
    try {
      final interactor = session.interactor..refuseNotHittable = refuse;
      final result = await interactor.run(scene, Tap(SymbolicTarget(glintId)));
      final response = StructuredResponse.fromActionResult(result);
      return arming is ArmingReady
          ? withArmedMetadata(response, arming)
          : response;
    } finally {
      await scene.dispose();
    }
  }
}
