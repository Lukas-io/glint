import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';

enum ScrollDirection { up, down, left, right }

class ScrollTool extends GlintTool {
  const ScrollTool();

  @override
  Tool get definition => Tool(
        name: 'scroll',
        description:
            'Scroll the screen in a direction (up/down/left/right). '
            'Direction is content-relative: "down" moves content down (finger swipes up). '
            'Anchors the swipe at viewport center. amountFraction controls how far '
            '(0.0–1.0, default 0.6 = 60% of viewport per scroll). '
            'For finding off-screen items, prefer scroll_to_find which loops until '
            'the target appears. '
            'With returnScene: true (default), settles and returns the new scene '
            'plus changed + changeCategory so you know if content actually moved.',
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
            'returnScene': Schema.bool(
              description:
                  'After the scroll, settle and return changed (bool) and '
                  'changeCategory. Default true.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'When true: also include the full rendered scene text as '
                  'postScene. Default false.',
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
    final returnScene = (args['returnScene'] as bool?) ?? true;
    final fetchScene = (args['fetchScene'] as bool?) ?? false;

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

    // Device mode: no Flutter viewport probe — swipe from center using the
    // device's screenshot-pixel dims (coordinateSwipe handles the dpr=1 ratio).
    if (session.isDeviceMode) {
      final device = session.device;
      if (device is! IosSimulator) {
        return StructuredResponse.error(
          summary: 'device-mode scroll is only supported on iOS simulators',
          errorKind: GlintErrorKind.unsupportedBackendAction,
        );
      }
      final w = device.logicalWidth;
      final h = device.logicalHeight;
      final dx = (dir == ScrollDirection.left
              ? -w
              : dir == ScrollDirection.right
                  ? w
                  : 0) *
          amount;
      final dy = (dir == ScrollDirection.up
              ? -h
              : dir == ScrollDirection.down
                  ? h
                  : 0) *
          amount;
      return coordinateSwipe(
          session, w / 2, h / 2, w / 2 - dx, h / 2 - dy, 300,
          verb: 'scrolled');
    }

    final pre = returnScene ? await snapshotPreAction(session) : null;

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

    // Backend speaks physical pixels. Note the sign flip: scroll DOWN means
    // "move content down" = swipe finger UP.
    final fromX = centerXLogical * vp.dpr;
    final fromY = centerYLogical * vp.dpr;
    final toX = (centerXLogical - deltaXLogical) * vp.dpr;
    final toY = (centerYLogical - deltaYLogical) * vp.dpr;

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        Swipe(
          CoordinateTarget(x: fromX, y: fromY),
          CoordinateTarget(x: toX, y: toY),
        ),
      );
      var response = StructuredResponse.fromActionResult(result);
      if (returnScene && !response.isError) {
        final post = await readPostActionState(session, pre,
            includeSceneText: fetchScene);
        if (post != null) {
          response = StructuredResponse(
            summary: response.summary,
            warnings: response.warnings,
            nextSteps: response.nextSteps,
            isError: response.isError,
            data: {...?response.data, ...post.toData()},
          );
        }
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }
}
