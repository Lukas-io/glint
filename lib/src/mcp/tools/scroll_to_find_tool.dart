import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import 'scroll_tool.dart';

/// Loops `get_scene` + `scroll` until a target (glintId or text content)
/// is hittable, or the ceiling is reached. Stops early if already visible.
class ScrollToFindTool extends GlintTool {
  const ScrollToFindTool();

  @override
  Tool get definition => Tool(
        name: 'scroll_to_find',
        description: 'Scroll until a target shows up hittable. Match by either '
            '`targetGlintId` (exact id) or `targetTextContent` '
            '(text node whose content contains the substring).',
        inputSchema: ObjectSchema(
          properties: {
            'targetGlintId': Schema.string(
              description: 'Stable id to find. Mutually exclusive with `targetTextContent`.',
            ),
            'targetTextContent': Schema.string(
              description:
                  'Substring to match against any text node\'s content. '
                  'Useful when the compact renderer collapsed the id you wanted.',
            ),
            'direction': Schema.string(
              description: 'One of: up, down, left, right. Default down.',
            ),
            'maxScrolls': Schema.int(
              description: 'Attempt ceiling. Default 8.',
            ),
            'amountFraction': Schema.num(
              description: 'Scroll size per step. Default 0.6.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final targetGlintId = args['targetGlintId'] as String?;
    final targetText = args['targetTextContent'] as String?;
    final dirName = (args['direction'] as String?) ?? 'down';
    final maxScrolls = (args['maxScrolls'] as int?) ?? 8;
    final amount = ((args['amountFraction'] as num?) ?? 0.6).toDouble();

    if ((targetGlintId == null) == (targetText == null)) {
      return StructuredResponse.error(
        summary: 'exactly one of targetGlintId or targetTextContent is required',
        errorKind: GlintErrorKind.invalidArgument,
      );
    }

    final dir = ScrollDirection.values
        .where((d) => d.name == dirName)
        .firstOrNull;
    if (dir == null) {
      return StructuredResponse.error(
        summary: 'unknown scroll direction: $dirName',
        errorKind: GlintErrorKind.invalidArgument,
      );
    }

    final scrollArgs = CallToolRequest(name: 'scroll', arguments: {
      'direction': dir.name,
      'amountFraction': amount,
    });
    final scroller = const ScrollTool();
    final criterion = targetGlintId != null
        ? 'glintId=$targetGlintId'
        : 'text~"$targetText"';

    for (var i = 0; i <= maxScrolls; i++) {
      final scene = await session.reader.readSummary();
      try {
        final hit = targetGlintId != null
            ? scene.findByGlintId(targetGlintId)
            : _findTextNode(scene.root, targetText!);
        if (hit != null && hit.glintId != null) {
          try {
            final coord = await session.resolver.resolve(scene, hit.glintId!);
            if (coord.hittable) {
              return StructuredResponse(
                summary: 'found $criterion after $i scroll(s)',
                data: {
                  'attempts': i,
                  'glintId': hit.glintId,
                  'hittable': true,
                  'painted': coord.painted,
                  if (hit.textPreview != null) 'matchedText': hit.textPreview,
                },
              );
            }
          } on Exception {
            // resolve can fail mid-scroll if the node was just replaced;
            // fall through and try another scroll.
          }
        }
      } finally {
        await scene.dispose();
      }

      if (i == maxScrolls) break;
      final step = await scroller.handle(session, scrollArgs);
      if (step.isError) {
        return StructuredResponse.error(
          summary: 'scroll step $i failed; aborting scroll_to_find',
          errorKind: GlintErrorKind.internal,
          detail: step.summary,
        );
      }
    }

    return StructuredResponse.error(
      summary: '$criterion not found after $maxScrolls scroll(s) in $dirName',
      errorKind: GlintErrorKind.unresolvedTarget,
      nextSteps: const [
        'try a different `direction`',
        'increase `maxScrolls`',
        'read the current scene with `get_scene` and pick a different target',
      ],
    );
  }

  SceneNode? _findTextNode(SceneNode root, String needle) {
    for (final n in root.walk()) {
      final preview = n.textPreview;
      if (preview != null && preview.contains(needle)) return n;
    }
    return null;
  }
}
