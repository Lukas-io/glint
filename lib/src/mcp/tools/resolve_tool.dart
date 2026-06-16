import 'package:dart_mcp/server.dart';

import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Read-only geometry lookup. Resolves a glintId against the live render
/// tree and returns its physical-pixel center, bounds, painted, hittable
/// flags — without side effects. Use this when you need to know *where*
/// a node is without firing a gesture against it.
class ResolveTool extends GlintTool {
  const ResolveTool();

  @override
  Tool get definition => Tool(
        name: 'resolve',
        description:
            'Drill-down geometry for a glintId. Returns: physicalCenter (px), '
            'logicalBounds (logical px), logicalViewSize, devicePixelRatio, '
            'painted (visible to human), hittable (would receive a tap), '
            'and warnings (e.g. "target is not painted", "target is not hittable"). '
            'Use this when an action fails or behaves unexpectedly — resolve the '
            'target to understand its true position and hit-test state before retrying. '
            'No side effects. Works on both base-screen and overlay glintIds.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description: 'Stable id from `get_scene`.',
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

    final scene = await session.reader.readSummary();
    try {
      final c = await session.resolver.resolve(scene, glintId);
      return StructuredResponse(
        summary: 'resolved $glintId at (${c.physicalCenter.x}, '
            '${c.physicalCenter.y}) px '
            '(painted=${c.painted}, hittable=${c.hittable})',
        warnings: c.warnings,
        data: c.toJson(),
      );
    } finally {
      await scene.dispose();
    }
  }
}
