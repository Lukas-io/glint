import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../coordinate.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

enum ScrollDirection { up, down, left, right }

/// Rest at the end of a scroll swipe so the list stops where the finger does instead of flinging on.
const scrollHoldMs = 120;

class ScrollTool extends GlintTool {
  const ScrollTool();

  @override
  Tool get definition => Tool(
        name: 'scroll',
        description:
            'Scroll up/down/left/right, content-relative: down shows what is below. Swipes inside the visible part of the main scrollable, above the keyboard; amountFraction 0.0 to 1.0 (default 0.6). When nothing moved, reason says why: atEnd, atStart, notScrollable or blocked. To find an off-screen item use scroll_to_find.',
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
                  'Settle, then report changed and changeCategory. Default true.',
            ),
            'fetchScene': Schema.bool(
              description:
                  'Also return the new scene text as postScene. Default false.',
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
    final amount = (argNum(args, 'amountFraction') ??
            session.config.scrollAmountFraction)
        .toDouble();
    final returnScene = argBool(args, 'returnScene') ?? true;
    final fetchScene = argBool(args, 'fetchScene') ?? false;

    final dir = enumByName(ScrollDirection.values, dirName);
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
      final line = _swipeLine(dir, amount,
          (x: 0.0, y: 0.0, w: size.w.toDouble(), h: size.h.toDouble()));
      return coordinateSwipe(
          session, line.fromX, line.fromY, line.toX, line.toY, 300,
          verb: 'scrolled', holdMs: scrollHoldMs);
    }

    final horizontal =
        dir == ScrollDirection.left || dir == ScrollDirection.right;
    final action = await openActionScene(session, snapshot: returnScene);
    try {
      final anchor = action.semantic == null
          ? null
          : await session.scrollAnchorIn(action.scene, action.semantic!);
      final ({double logicalW, double logicalH, double dpr}) vp;
      try {
        vp = await session.viewportIn(action.scene);
      } on GeometryResolveError catch (e) {
        return StructuredResponse.error(
          summary: 'scroll could not measure the viewport',
          errorKind: GlintErrorKind.geometryResolveError,
          detail: e.message,
          nextSteps: const [
            'the screen may be mid-transition — wait_for_settle, then retry',
            'or pass x1,y1,x2,y2 to swipe by coordinates',
          ],
        );
      }
      final keyboard = (await session.uiState()).keyboardBottomPx / vp.dpr;
      final region = swipeRegion(
          (x: 0.0, y: 0.0, w: vp.logicalW, h: vp.logicalH - keyboard), anchor?.clip);
      final line = _swipeLine(dir, amount, region);
      var response = await coordinateSwipe(
          session, line.fromX, line.fromY, line.toX, line.toY, 300,
          verb: 'scrolled', holdMs: scrollHoldMs);
      if (returnScene && !response.isError) {
        final post = await readPostActionState(session, action.pre,
            includeSceneText: fetchScene,
            scrollAnchor: anchor,
            horizontalScroll: horizontal);
        if (post != null) {
          final movedPx = post.scrolledPx;
          final merged = mergeScrollSignal(post.changeCategory, movedPx);
          response = response.mergeData({
            ...post.toData(),
            'changed': merged.changed,
            'changeCategory': merged.category,
            if (movedPx != null) 'scrolledPx': movedPx.round(),
          });
          if (!merged.changed) {
            final reason = await _whyStill(session, action.scene, anchor, dir);
            response = response.copyWith(
              summary: '${response.summary}; nothing moved: ${_reasonText[reason]}',
            ).mergeData({'reason': reason});
          }
        }
      }
      return response;
    } finally {
      await action.dispose();
    }
  }

  /// Below this a scroll didn't meaningfully move — treat as no scroll.
  static const _movedThresholdPx = 2.0;

  /// Merge the tree-hash change category with physical anchor movement. A
  /// fully-realized scrollable's tree is identical at every offset, so the
  /// hash reports 'nothing' even when content moved — promote that to
  /// 'scrolled' when the anchor physically shifted.
  static ({bool changed, String category}) mergeScrollSignal(
      String treeCategory, double? movedPx) {
    final moved = movedPx != null && movedPx > _movedThresholdPx;
    if (treeCategory == 'nothing' && moved) {
      return (changed: true, category: 'scrolled');
    }
    return (changed: treeCategory != 'nothing', category: treeCategory);
  }

  /// Keeps the whole gesture this far inside each screen edge — off-screen
  /// endpoints get clamped by the OS and can trip system edge gestures.
  static const _edgeMarginFraction = 0.06;

  /// Swipe travel centered on [r], clamped inside the edge margin.
  /// Content moves toward [dir], so the finger travels the opposite way.
  ({double fromX, double fromY, double toX, double toY}) _swipeLine(
      ScrollDirection dir, double amount, Rect4 r) {
    final horizontal =
        dir == ScrollDirection.left || dir == ScrollDirection.right;
    final span = horizontal ? r.w : r.h;
    final margin = span * _edgeMarginFraction;
    final travel = (span * amount).clamp(0.0, span - 2 * margin);
    final sign =
        (dir == ScrollDirection.right || dir == ScrollDirection.down) ? -1 : 1;
    final cx = r.x + r.w / 2, cy = r.y + r.h / 2;
    final half = sign * travel / 2;
    return horizontal
        ? (fromX: cx - half, fromY: cy, toX: cx + half, toY: cy)
        : (fromX: cx, fromY: cy - half, toX: cx, toY: cy + half);
  }

  static const _reasonText = {
    'atEnd': 'already at the end',
    'atStart': 'already at the start',
    'notScrollable': 'nothing scrollable on this screen',
    'blocked': 'the list can still move, so the swipe did not reach it (an overlay or the keyboard may be in the way)',
  };

  /// Why a scroll moved nothing, from the scrollable's own position.
  Future<String> _whyStill(GlintSession session, Scene scene,
      ScrollAnchor? anchor, ScrollDirection dir) async {
    final node = anchor == null ? null : scene.findByGlintId(anchor.glintId);
    if (node == null) return 'notScrollable';
    final raw = await session.runtime.evaluateWithSelection(
      expression: _positionExpr,
      inspectorId: node.inspectorId,
      groupName: scene.groupName,
    );
    final parts = raw?.split(',').map(double.tryParse).toList();
    if (parts == null || parts.length != 3 || parts.contains(null)) {
      return raw == 'none' ? 'notScrollable' : 'blocked';
    }
    final (pixels, min, max) = (parts[0]!, parts[1]!, parts[2]!);
    final forward = dir == ScrollDirection.down || dir == ScrollDirection.right;
    if (forward && pixels >= max - 1) return 'atEnd';
    if (!forward && pixels <= min + 1) return 'atStart';
    return 'blocked';
  }

  static const _positionExpr =
      "((ScrollPosition? p) => p == null ? 'none' : p.pixels.toString() + ',' + "
      "p.minScrollExtent.toString() + ',' + p.maxScrollExtent.toString())"
      '(Scrollable.maybeOf(WidgetInspectorService.instance.selection.currentElement!)?.position)';
}

typedef Rect4 = ({double x, double y, double w, double h});

/// Where to swipe: [screen] (already above the keyboard) narrowed to the scrollable's visible [clip]; falls back to [screen] when the overlap is too small to swipe in.
Rect4 swipeRegion(Rect4 screen, Rect4? clip) {
  if (clip == null) return screen;
  final x = clip.x > screen.x ? clip.x : screen.x;
  final y = clip.y > screen.y ? clip.y : screen.y;
  final right = (clip.x + clip.w) < (screen.x + screen.w) ? clip.x + clip.w : screen.x + screen.w;
  final bottom = (clip.y + clip.h) < (screen.y + screen.h) ? clip.y + clip.h : screen.y + screen.h;
  if (right - x < 80 || bottom - y < 80) return screen;
  return (x: x, y: y, w: right - x, h: bottom - y);
}
