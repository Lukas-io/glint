import 'coordinate.dart';
import 'envelope.dart';
import 'post_action.dart';
import 'session.dart';
import 'tools/scroll_tool.dart';

/// A raw x1,y1 to x2,y2 gesture for swipe and drag: refuses off-screen points, and in Flutter mode reports a scroll under the start point as `scrolled` with `scrolledPx`.
Future<StructuredResponse> segmentSwipe(
  GlintSession session,
  String tool,
  ({double x1, double y1, double x2, double y2}) seg,
  int durationMs, {
  required String verb,
  required bool returnScene,
  required bool fetchScene,
}) async {
  final off = await rejectOffScreen(session, tool, segmentCoordinates(seg));
  if (off != null) return off;
  Future<StructuredResponse> fire() => coordinateSwipe(session, seg.x1, seg.y1, seg.x2, seg.y2, durationMs, verb: verb);
  if (session.isDeviceMode || !returnScene) return fire();

  final ActionScene action;
  try {
    action = await openActionScene(session, snapshot: true);
  } on Object {
    return fire();
  }
  try {
    final semantic = action.semantic;
    final anchor = semantic == null ? null : await session.scrollAnchorAt(action.scene, semantic, seg.x1, seg.y1);
    final response = await fire();
    if (response.isError) return response;
    final horizontal = (seg.x2 - seg.x1).abs() > (seg.y2 - seg.y1).abs();
    final post = await readPostActionState(session, action.pre,
        includeSceneText: fetchScene, scrollAnchor: anchor, horizontalScroll: horizontal);
    if (post == null) return response;
    final movedPx = post.scrolledPx;
    final merged = ScrollTool.mergeScrollSignal(post.changeCategory, movedPx);
    return response.mergeData({
      ...post.toData(),
      'changed': merged.changed,
      'changeCategory': merged.category,
      if (movedPx != null) 'scrolledPx': movedPx.round(),
    }).addWarnings([if (post.note != null) post.note!]);
  } finally {
    await action.dispose();
  }
}
