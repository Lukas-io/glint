import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import 'scroll_tool.dart';

/// Loops `get_scene` + `scroll` until `targetGlintId` shows up hittable
/// or the attempt ceiling is reached. Stops early if the target is
/// already visible.
class ScrollToFindTool extends GlintTool {
  const ScrollToFindTool();

  @override
  Tool get definition => Tool(
        name: 'scroll_to_find',
        description:
            'Scroll until a target glintId becomes hittable, or give up after a ceiling.',
        inputSchema: ObjectSchema(
          properties: {
            'targetGlintId': Schema.string(
              description: 'Stable id to find.',
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
          required: ['targetGlintId'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final target = args['targetGlintId']! as String;
    final dirName = (args['direction'] as String?) ?? 'down';
    final maxScrolls = (args['maxScrolls'] as int?) ?? 8;
    final amount = ((args['amountFraction'] as num?) ?? 0.6).toDouble();

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

    for (var i = 0; i <= maxScrolls; i++) {
      final scene = await session.reader.readSummary();
      try {
        final node = scene.findByGlintId(target);
        if (node != null) {
          // Found in tree. Resolve to confirm hittable.
          try {
            final coord = await session.resolver.resolve(scene, target);
            if (coord.hittable) {
              return StructuredResponse(
                summary: 'found $target after $i scroll(s)',
                data: {
                  'attempts': i,
                  'glintId': target,
                  'hittable': true,
                  'painted': coord.painted,
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
      summary: '$target not found after $maxScrolls scroll(s) in $dirName',
      errorKind: GlintErrorKind.unresolvedTarget,
      nextSteps: const [
        'try a different `direction`',
        'increase `maxScrolls`',
        'read the current scene with `get_scene` and pick a different glintId',
      ],
    );
  }
}
