import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
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
      if (scene.findByGlintId(glintId) == null) {
        return StructuredResponse.error(
          summary: 'no node with glintId "$glintId" in the current scene',
          errorKind: GlintErrorKind.unresolvedTarget,
          nextSteps: const ['re-run get_scene to read current glintIds'],
        );
      }
      final c = await session.resolver.resolve(scene, glintId);
      return StructuredResponse(
        summary: 'resolved $glintId at (${c.physicalCenter.x}, '
            '${c.physicalCenter.y}) px '
            '(painted=${c.painted}, hittable=${c.hittable})',
        warnings: c.warnings,
        data: c.toJson(),
      );
    } on GeometryResolveError catch (e) {
      // Same failure the interactor maps cleanly — resolve must not leak it as
      // a raw `internal` stack trace. A non-string eval usually means the node
      // has no usable geometry (offstage/zero-size) or the app's VM is wedged.
      return StructuredResponse.error(
        summary: 'could not resolve geometry for $glintId',
        errorKind: GlintErrorKind.geometryResolveError,
        detail: e.message,
        nextSteps: const [
          'the element may be offstage or zero-size — get_scene to confirm it is on screen',
          'if the app just threw or hot-reloaded, its VM may be wedged — re-attach or hot-restart',
        ],
      );
    } finally {
      await scene.dispose();
    }
  }
}
