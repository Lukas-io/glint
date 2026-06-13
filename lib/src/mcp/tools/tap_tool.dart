import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class TapTool extends GlintTool {
  const TapTool();

  @override
  Tool get definition => Tool(
        name: 'tap',
        description:
            'Tap a node by its glintId (as shown in `get_scene`). '
            'Returns the structured ActionResult. By default, tapping a target that is painted but '
            'not hittable returns ok=true with a warning; pass `refuseNotHittable: true` to refuse instead.',
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

    final scene = await session.reader.readSummary();
    try {
      final interactor = session.interactor..refuseNotHittable = refuse;
      final result = await interactor.run(scene, Tap(SymbolicTarget(glintId)));
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
