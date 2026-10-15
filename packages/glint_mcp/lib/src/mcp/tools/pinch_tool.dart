import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../native_target.dart';
import '../session.dart';
import '../text_target.dart';
import '../tool.dart';
import '../tool_args.dart';

class PinchTool extends GlintTool {
  const PinchTool();

  @override
  Tool get definition => Tool(
        name: 'pinch',
        description:
            'Two fingers around a node (glintId or visible text) or x,y, spreading (scale > 1, zoom in) or closing '
            '(scale < 1, zoom out). Inside the Flutter app with two pointers, or real multi-touch on a physical iPhone. '
            'Returns changed + changeCategory and data.input like any gesture. '
            'errorKind: invalidArgument, unresolvedTarget, unsupportedBackendAction.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(description: 'Stable id from get_scene: pinch around its center.'),
            'text': Schema.string(description: 'Visible text of the target instead of glintId.'),
            'x': Schema.num(description: 'Center x in logical points (device mode: screenshot pixels), with y.'),
            'y': Schema.num(description: 'Center y, with x.'),
            'scale': Schema.num(
                description: 'How far apart the fingers end relative to where they start: 2 zooms in, 0.5 zooms out.'),
            'durationMs': Schema.int(description: 'Gesture length in ms. Default 400.'),
            'returnScene': Schema.bool(description: 'Settle, then report changed and changeCategory. Default true.'),
          },
          required: ['scale'],
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final scale = (args['scale'] as num?)?.toDouble();
    if (scale == null || scale <= 0 || scale == 1) {
      return StructuredResponse.error(
        summary: 'scale must be a positive number other than 1',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['scale:2 zooms in, scale:0.5 zooms out'],
      );
    }
    final durationMs = argInt(args, 'durationMs') ?? 400;
    final t = readTargetedArgs(args, session.config);
    var center = readPoint(args);
    String? label;
    if (center == null) {
      final native =
          await resolveNativeTarget(session, glintId: args['glintId'] as String?, text: args['text'] as String?);
      if (native?.error case final error?) return error;
      if (native?.hit case final hit?) {
        center = (x: hit.x, y: hit.y);
        label = hit.label;
      } else {
        final target = await readTarget(session, args, t, tool: 'pinch');
        if (target.error != null) return target.error!;
        final scene = await session.reader.readSummary();
        try {
          final c = await session.resolver.resolve(scene, target.glintId!);
          center = (x: c.logicalCenter.x, y: c.logicalCenter.y);
          label = target.glintId;
        } finally {
          await scene.dispose();
        }
      }
    }
    final at = center;
    return withCoordinateChange(session, () => coordinatePinch(session, at.x, at.y, scale, durationMs, label: label),
        returnScene: t.returnScene);
  }
}
