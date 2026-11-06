import '../../observability.dart' show FlutterErrorEntry;
import '../runtime/flutter_runtime.dart';

/// Walks the render tree once and counts on-screen scrollables that hold built children, none of which laid out into a finite size; type names are compared as strings so it compiles in any eval library.
const _emptyViewportExpr = '(() { var blank = 0; '
    'void kids(dynamic s, List<int> n) { '
    'var c; try { c = s.firstChild; } catch (_) { c = null; } '
    'if (c != null) { while (c != null) { n[0]++; '
    'try { if (!c.debugNeedsLayout && c.hasSize && c.size.isFinite) n[1]++; } catch (_) {} '
    'c = s.childAfter(c); } return; } '
    'if (s.runtimeType.toString().startsWith("RenderSliver")) { '
    's.visitChildren((x) { if (x.runtimeType.toString().startsWith("RenderSliver")) kids(x, n); }); } } '
    'void walk(dynamic r) { final t = r.runtimeType.toString(); '
    'if (t == "RenderOffstage" && r.offstage == true) return; '
    'if (t == "RenderViewport" || t == "RenderShrinkWrappingViewport") { '
    'var sized = false; '
    'try { sized = r.attached == true && r.size.width > 0 && r.size.height > 0; } catch (_) {} '
    'if (sized) { final n = [0, 0]; r.visitChildren((s) { kids(s, n); }); if (n[0] > 0 && n[1] == 0) blank++; } } '
    'r.visitChildren(walk); } '
    'for (final view in RendererBinding.instance.renderViews) { walk(view); } return blank.toString(); })()';

/// How many on-screen scrollables hold built children but none that laid out, or null when it cannot be read (device mode, eval failure).
Future<int?> emptyViewportCount(FlutterRuntime runtime) async {
  try {
    final raw = await runtime.evaluateString(_emptyViewportExpr);
    return raw == null ? null : int.tryParse(raw);
  } on Object {
    return null;
  }
}

/// `0 errors`, or `2 errors: <first> (lib/x.dart:12); <second>` with a tail count past three.
String errorsHeadline(List<FlutterErrorEntry> errors) {
  if (errors.isEmpty) return '0 errors';
  final shown = errors.take(3).map((e) => e.line).join('; ');
  final more = errors.length > 3 ? '; +${errors.length - 3} more' : '';
  return '${errors.length} error${errors.length == 1 ? '' : 's'}: $shown$more';
}

/// One warning for [e]: `error: summary (location) x3`, counting occurrences after feed seq [since].
String errorWarning(FlutterErrorEntry e, int since) {
  final n = e.countSince(since);
  return 'error: ${e.line}${n > 1 ? ' x$n' : ''}';
}

/// The warning for [count] scrollables that hold built children yet painted none.
String emptyViewportWarning(int count) =>
    'emptyViewport: ${count == 1 ? 'a scrollable' : '$count scrollables'} on screen holds built children but painted '
    'none, so the blank area is a layout failure, not an empty state';
