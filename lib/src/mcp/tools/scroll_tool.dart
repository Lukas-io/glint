import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

enum ScrollDirection { up, down, left, right }

class ScrollTool extends GlintTool {
  const ScrollTool();

  @override
  Tool get definition => Tool(
        name: 'scroll',
        description:
            'Scroll the screen by direction. Anchors on viewport center; the swipe '
            'covers 60% of the viewport by default. Use `amountFraction` to override.',
        inputSchema: ObjectSchema(
          properties: {
            'direction': Schema.string(
              description:
                  'One of: ${ScrollDirection.values.map((d) => d.name).join(', ')}',
            ),
            'amountFraction': Schema.num(
              description:
                  'Fraction of viewport to travel (0.0–1.0). Default 0.6.',
            ),
          },
          required: ['direction'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final dirName = args['direction']! as String;
    final amount = ((args['amountFraction'] as num?) ??
            session.config.scrollAmountFraction)
        .toDouble();

    final dir = ScrollDirection.values
        .where((d) => d.name == dirName)
        .firstOrNull;
    if (dir == null) {
      return StructuredResponse.error(
        summary: 'unknown scroll direction: $dirName',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: [
          'use one of: ${ScrollDirection.values.map((d) => d.name).join(', ')}'
        ],
      );
    }

    final vp = await session.probeViewport();
    final centerXLogical = vp.logicalW / 2;
    final centerYLogical = vp.logicalH / 2;
    final deltaXLogical = (dir == ScrollDirection.left
            ? -vp.logicalW
            : dir == ScrollDirection.right
                ? vp.logicalW
                : 0) *
        amount;
    final deltaYLogical = (dir == ScrollDirection.up
            ? -vp.logicalH
            : dir == ScrollDirection.down
                ? vp.logicalH
                : 0) *
        amount;

    // Backend speaks physical pixels.
    final fromX = centerXLogical * vp.dpr;
    final fromY = centerYLogical * vp.dpr;
    final toX = (centerXLogical - deltaXLogical) * vp.dpr;
    final toY = (centerYLogical - deltaYLogical) * vp.dpr;

    // Note the sign flip: scroll DOWN means "move content down" = swipe finger UP.

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(
          CoordinateTarget(x: fromX, y: fromY),
          CoordinateTarget(x: toX, y: toY),
        ),
      );
      return StructuredResponse.fromActionResult(result);
    } finally {
      await scene.dispose();
    }
  }
}
