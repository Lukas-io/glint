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

    // Device mode: no Flutter viewport probe — use the device's screen size.
    if (session.isDeviceMode) {
      final size = session.device.screenSize;
      if (size == null) {
        return StructuredResponse.error(
          summary: 'device-mode scroll needs a known screen size; none available',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          nextSteps: const [
            'take a `device op:screenshot` and use swipe x1,y1,x2,y2',
          ],
        );
      }
      final line = _swipeLine(dir, amount, size.w.toDouble(), size.h.toDouble());
      return coordinateSwipe(
          session, line.fromX, line.fromY, line.toX, line.toY, 300,
          verb: 'scrolled');
    }

    final pre = returnScene ? await snapshotPreAction(session) : null;

    final vp = await session.probeViewport();
    final line = _swipeLine(dir, amount, vp.logicalW, vp.logicalH);
    var response = await coordinateSwipe(
        session, line.fromX, line.fromY, line.toX, line.toY, 300,
        verb: 'scrolled');
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
  }

  /// Keeps the whole gesture this far inside each screen edge — off-screen
  /// endpoints get clamped by the OS and can trip system edge gestures.
  static const _edgeMarginFraction = 0.06;

  /// Swipe travel centered on the viewport, clamped inside the edge margin.
  /// Content moves toward [dir], so the finger travels the opposite way.
  ({double fromX, double fromY, double toX, double toY}) _swipeLine(
      ScrollDirection dir, double amount, double w, double h) {
    final horizontal =
        dir == ScrollDirection.left || dir == ScrollDirection.right;
    final span = horizontal ? w : h;
    final margin = span * _edgeMarginFraction;
    final travel = (span * amount).clamp(0.0, span - 2 * margin);
    final sign =
        (dir == ScrollDirection.right || dir == ScrollDirection.down) ? -1 : 1;
    final cx = w / 2, cy = h / 2;
    final half = sign * travel / 2;
    return horizontal
        ? (fromX: cx - half, fromY: cy, toX: cx + half, toY: cy)
        : (fromX: cx, fromY: cy - half, toX: cx, toY: cy + half);
  }
}
