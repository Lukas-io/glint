import '../../perception.dart' show CreationLocation, SceneNode;
import '../../semantic.dart' show SemanticScene;
import '../runtime/flutter_runtime.dart';
import 'watch_conditions.dart';
import 'watch_observation.dart';

/// Cheap layout signature: insets, view size, a hash of every laid-out box size, and where the focused field sits.
final String lintProbeExpr = _probeSource.replaceAll('\n', ' ');

const String _probeSource = r'''
(() {
  final m = 0x3fffffff;
  var h = 0;
  var s = '';
  for (final rv in RendererBinding.instance.renderViews) {
    final fv = rv.flutterView;
    final d = fv.devicePixelRatio;
    s += (fv.viewInsets.bottom / d).toStringAsFixed(1) + ',' + (fv.viewPadding.top / d).toStringAsFixed(1) + ',' + (fv.viewPadding.bottom / d).toStringAsFixed(1) + ',' + fv.physicalSize.width.toString() + 'x' + fv.physicalSize.height.toString() + ';';
    void w(dynamic o) {
      final t = o.runtimeType.toString();
      if (t == 'RenderOffstage' && o.offstage == true) return;
      if (t != 'RenderView' && !t.startsWith('RenderSliver')) {
        try {
          if (o.hasSize) {
            h = (h * 31 + ((o.size.width * 8).round() as int)) & m;
            h = (h * 31 + ((o.size.height * 8).round() as int)) & m;
            if (t == 'RenderEditable' && o.hasFocus == true) h = (h * 31 + ((o.localToGlobal(Offset.zero).dy * 4).round() as int)) & m;
          }
        } catch (_) {}
      }
      o.visitChildren(w);
    }
    w(rv);
  }
  return s + h.toString();
})()
''';

const String _walkTemplate = r'''
(() {
  final svc = WidgetInspectorService.instance;
  final group = '@@GROUP@@';
  final rules = <String>{@@RULES@@};
  final minTap = @@MIN_TAP@@;
  final maxHeadline = @@MAX_LINES@@;
  final out = <String>[];
  final counts = <String, int>{};
  String n(double v) => v.toStringAsFixed(1);
  String clean(String s) {
    final t = s.replaceAll('\n', ' ').replaceAll('|', ' ').replaceAll(';', ' ').replaceAll('=', ' ').replaceAll(',', ' ').trim();
    return t.length > 50 ? t.substring(0, 49) : t;
  }
  void add(String rule, dynamic r, double x, double y, double w, double h, String detail) {
    final c = counts[rule] ?? 0;
    if (c >= 15) return;
    counts[rule] = c + 1;
    final ids = <String>[];
    try {
      final el = (r.debugCreator as dynamic).element;
      ids.add(svc.toId(el, group)!);
      el.visitAncestorElements((a) { ids.add(svc.toId(a, group)!); return ids.length < 40; });
    } catch (_) {}
    out.add('F|' + rule + '|' + r.runtimeType.toString() + '|' + n(x) + ',' + n(y) + ',' + n(w) + ',' + n(h) + '|' + detail + '|' + ids.join(','));
  }
  int lineCount(dynamic r, int length) {
    final boxes = r.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length)) as List;
    var lines = 0;
    var lineBottom = -1.0e9;
    for (final b in boxes) {
      if (b.top >= lineBottom - 1.0) { lines++; lineBottom = b.bottom; }
      else if (b.bottom > lineBottom) { lineBottom = b.bottom; }
    }
    return lines;
  }
  bool scrolling(dynamic r) {
    try { return RenderAbstractViewport.maybeOf(r) != null; } catch (_) { return false; }
  }
  List<double> hitSize(dynamic r, double w, double h) {
    dynamic p = r.parent;
    for (var i = 0; i < 8 && p != null; i++) {
      if (p.runtimeType.toString() == '_RenderInputPadding') return [p.size.width as double, p.size.height as double];
      p = p.parent;
    }
    return [w, h];
  }
  for (final rv in RendererBinding.instance.renderViews) {
    final fv = rv.flutterView;
    final dpr = fv.devicePixelRatio;
    final vw = fv.physicalSize.width / dpr;
    final vh = fv.physicalSize.height / dpr;
    final top = fv.viewPadding.top / dpr;
    final bottom = fv.viewPadding.bottom / dpr;
    final kb = fv.viewInsets.bottom / dpr;
    out.add('H|' + n(vw) + '|' + n(vh) + '|' + n(top) + '|' + n(bottom) + '|' + n(kb));
    void visit(dynamic r, String t) {
      if (t == 'RenderView' || t.startsWith('RenderSliver') || !r.hasSize) return;
      final o = r.localToGlobal(Offset.zero);
      final x = o.dx as double;
      final y = o.dy as double;
      final w = r.size.width as double;
      final h = r.size.height as double;
      if (t == 'RenderEditable' && kb > 0.5 && rules.contains('keyboard') && r.hasFocus == true) {
        var edge = y + h;
        if (r.maxLines != 1) {
          try {
            final sel = r.selection;
            if (sel != null && sel.isValid) edge = r.localToGlobal(r.getLocalRectForCaret(sel.extent).bottomLeft).dy as double;
          } catch (_) {}
        }
        final kbTop = vh - kb;
        if (edge > kbTop + 0.5) add('keyboard', r, x, y, w, h, 'covered=' + n(edge - kbTop) + ';keyboardTop=' + n(kbTop) + ';fieldBottom=' + n(edge));
      }
      if (w <= 0 || h <= 0 || !(x + w > 0 && y + h > 0 && x < vw && y < vh)) return;
      if (t == 'RenderFlex' && rules.contains('overflow')) {
        final horizontal = r.direction.index == 0;
        final extent = horizontal ? w : h;
        var past = 0.0;
        var before = 0.0;
        r.visitChildren((dynamic c) {
          if (c.runtimeType.toString().startsWith('RenderSliver') || !c.hasSize) return;
          final off = (c.parentData as dynamic).offset;
          final start = (horizontal ? off.dx : off.dy) as double;
          final end = start + (horizontal ? c.size.width : c.size.height);
          if (end - extent > past) past = end - extent;
          if (-start > before) before = -start;
        });
        if (past > 0.5 || before > 0.5) {
          final amount = past > before ? past : before;
          final edge = horizontal ? (past > before ? 'right' : 'left') : (past > before ? 'bottom' : 'top');
          add('overflow', r, x, y, w, h, 'amount=' + n(amount) + ';edge=' + edge + ';axis=' + (horizontal ? 'horizontal' : 'vertical'));
        }
      }
      if (t == 'RenderSemanticsGestureHandler' && rules.contains('tapTarget') && r.onTap != null) {
        final hit = hitSize(r, w, h);
        if (hit[0] < minTap || hit[1] < minTap) add('tapTarget', r, x, y, hit[0], hit[1], 'width=' + n(hit[0]) + ';height=' + n(hit[1]) + ';min=' + n(minTap));
      }
      var text = '';
      if (t == 'RenderParagraph') {
        final plain = r.text.toPlainText() as String;
        if (plain.trim().isEmpty) return;
        text = clean(plain);
        if (rules.contains('clippedText') && r.didExceedMaxLines == true) {
          add('clippedText', r, x, y, w, h, 'maxLines=' + r.maxLines.toString() + ';overflow=' + (r.overflow.name as String) + ';text=' + text);
        }
        if (rules.contains('lines')) {
          var fs = 0.0;
          try { fs = (r.text.style?.fontSize ?? 0.0) as double; } catch (_) {}
          if (fs >= 20.0) {
            final count = lineCount(r, plain.length);
            if (count > maxHeadline) add('lines', r, x, y, w, h, 'lines=' + count.toString() + ';max=' + maxHeadline.toString() + ';fontSize=' + n(fs) + ';text=' + text);
          }
        }
      }
      if (rules.contains('insets') && (t == 'RenderParagraph' || t == 'RenderEditable' || (t == 'RenderImage' && w <= 96 && h <= 96)) && !scrolling(r)) {
        if (top > 0.5 && y < top - 0.5) {
          add('insets', r, x, y, w, h, 'edge=top;inset=' + n(top) + ';into=' + n(top - y) + ';text=' + text);
        } else if (kb < 0.5 && bottom > 0.5 && y + h > vh - bottom + 0.5) {
          add('insets', r, x, y, w, h, 'edge=bottom;inset=' + n(bottom) + ';into=' + n(y + h - (vh - bottom)) + ';text=' + text);
        }
      }
    }
    void walk(dynamic r) {
      final t = r.runtimeType.toString();
      if (t == 'RenderOffstage' && r.offstage == true) return;
      if (t == 'RenderOpacity' && r.opacity == 0) return;
      if (t == 'RenderAnimatedOpacity') {
        try { if (r.opacity.value == 0) return; } catch (_) {}
      }
      try { visit(r, t); } catch (_) {}
      r.visitChildren(walk);
    }
    walk(rv);
  }
  return out.join('\n');
})()
''';

/// The one-walk lint expression for [spec], registering ancestors in inspector group [group].
String lintWalkExpr(LintCondition spec, String group) => _walkTemplate
    .replaceAll('\n', ' ')
    .replaceAll('@@GROUP@@', group)
    .replaceAll('@@RULES@@', spec.rules.map((r) => "'$r'").join(','))
    .replaceAll('@@MIN_TAP@@', '${spec.minTapTarget.toDouble()}')
    .replaceAll('@@MAX_LINES@@', '${spec.maxHeadlineLines}');

/// One UX problem, mapped to the nearest scene widget when the inspector knows it.
class LintFinding {
  LintFinding({
    required this.rule,
    required this.route,
    required this.widget,
    required this.rect,
    required this.measured,
    this.glintId,
    this.location,
    this.text,
  });

  final String rule;
  final String route;
  final String widget;
  final String? glintId;
  final String? location;
  final String? text;
  final ({double x, double y, double w, double h}) rect;
  final Map<String, Object?> measured;

  /// What identifies the same problem again: rule, widget and the numbers that make it that problem.
  String get key {
    final id = glintId ?? '$widget@${rect.w.round()}x${rect.h.round()}';
    final detail = switch (rule) {
      'clippedText' || 'lines' => text ?? '',
      'tapTarget' => '${rect.w.round()}x${rect.h.round()}',
      _ => '${measured['edge'] ?? ''}',
    };
    return '$rule|$id|$widget|$detail';
  }

  String get summary {
    final where = [if (glintId != null) glintId!, if (location != null) location!].join(', ');
    final head = switch (rule) {
      'overflow' => '$widget overflows ${measured['amount']} px past the ${measured['edge']} edge',
      'keyboard' => '$widget is ${measured['covered']} px under the keyboard (field bottom ${measured['fieldBottom']}, '
          'keyboard top ${measured['keyboardTop']})',
      'insets' => measured['edge'] == 'top'
          ? '$widget starts ${measured['into']} px inside the status bar (${measured['inset']} px tall)'
          : '$widget ends ${measured['into']} px inside the home indicator area (${measured['inset']} px tall)',
      'tapTarget' => '$widget tap target ${measured['width']}x${measured['height']}, under '
          '${measured['min']}x${measured['min']}',
      'clippedText' => 'text "$text" is clipped (maxLines ${measured['maxLines']}, overflow ${measured['overflow']})',
      'lines' => 'headline "$text" wraps to ${measured['lines']} lines (max ${measured['max']})',
      _ => widget,
    };
    return '$rule: $head${where.isEmpty ? '' : ' ($where)'}';
  }

  Map<String, Object?> toJson() => {
        'rule': rule,
        'widget': widget,
        if (glintId != null) 'glintId': glintId,
        if (location != null) 'location': location,
        'rect': {'x': rect.x, 'y': rect.y, 'w': rect.w, 'h': rect.h},
        'measured': measured,
      };
}

/// What one lint tick produced: findings new since the last check, or why the check cannot run.
typedef LintOutcome = ({List<LintFinding> fresh, String? error});

/// Runs the lint rules of one `{lint}` condition: waits for the screen to settle, walks the render tree once, and reports only what is new.
class LintWatcher {
  LintWatcher(this.spec);

  static const _maxUnsettledTicks = 8;
  static const _maxFreshPerCheck = 12;

  final LintCondition spec;
  String? _lastSignature;
  String? _checkedSignature;
  int _unsettled = 0;
  final Map<String, Set<String>> _fired = {};

  /// Whether the eval failed to compile; the condition then stays quiet.
  bool disabled = false;

  /// One tick: the first one checks at once, later ones only after the layout signature changed and then held still for a tick.
  Future<LintOutcome> tick(FlutterRuntime runtime, SemanticScene scene, WatchObservation obs) async {
    const none = (fresh: <LintFinding>[], error: null);
    try {
      final probe = await runtime.evaluateString(lintProbeExpr, rethrowErrors: true);
      if (probe == null) return (fresh: const <LintFinding>[], error: 'the layout probe returned no string');
      final signature = '$probe|${obs.route}|${obs.overlay}|${Object.hashAllUnordered(obs.labels)}|'
          '${Object.hashAllUnordered(obs.tappableIds)}';
      if (signature == _checkedSignature) {
        _lastSignature = signature;
        _unsettled = 0;
        return none;
      }
      final first = _lastSignature == null;
      if (signature != _lastSignature) {
        _lastSignature = signature;
        _unsettled++;
        if (!first && _unsettled < _maxUnsettledTicks) return none;
      }
      _unsettled = 0;
      final raw = await runtime.evaluateString(lintWalkExpr(spec, scene.sourceScene.groupName), rethrowErrors: true);
      if (raw == null) return (fresh: const <LintFinding>[], error: 'the lint walk returned no string');
      _checkedSignature = signature;
      return (fresh: _fresh(parseLintFindings(raw, scene.sourceScene.root, obs.route), obs.route), error: null);
    } on RuntimeEvalError catch (e) {
      disabled = true;
      return (fresh: const <LintFinding>[], error: e.message);
    }
  }

  List<LintFinding> _fresh(List<LintFinding> found, String route) {
    final held = _fired[route] ?? <String>{};
    final current = {for (final f in found) f.key};
    final fresh = <LintFinding>[];
    final emitted = <String>{};
    for (final f in found) {
      if (held.contains(f.key) || !emitted.add(f.key)) continue;
      if (fresh.length >= _maxFreshPerCheck) {
        emitted.remove(f.key);
        continue;
      }
      fresh.add(f);
    }
    _fired[route] = {...held.intersection(current), ...emitted};
    return fresh;
  }
}

/// Findings from a lint walk reply, each tied to the nearest scene node among its ancestor inspector ids.
List<LintFinding> parseLintFindings(String raw, SceneNode sceneRoot, String route) {
  final byInspector = <String, SceneNode>{};
  for (final n in sceneRoot.walk()) {
    if (n.glintId != null && n.inspectorId.isNotEmpty && !n.isOffstage) byInspector[n.inspectorId] = n;
  }
  final out = <LintFinding>[];
  for (final line in raw.split('\n')) {
    final parts = line.split('|');
    if (parts.length < 6 || parts.first != 'F') continue;
    final box = parts[3].split(',').map(double.tryParse).toList();
    if (box.length != 4 || box.contains(null)) continue;
    final measured = <String, Object?>{};
    String? text;
    for (final pair in parts[4].split(';')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final k = pair.substring(0, eq);
      final v = pair.substring(eq + 1);
      if (k == 'text') {
        text = v.isEmpty ? null : v;
      } else {
        measured[k] = num.tryParse(v) ?? v;
      }
    }
    SceneNode? node;
    for (final id in parts[5].split(',')) {
      node = byInspector[id];
      if (node != null) break;
    }
    out.add(LintFinding(
      rule: parts[1],
      route: route,
      widget: node?.baseLabel ?? parts[2],
      glintId: node?.glintId,
      location: node?.creationLocation == null ? null : _place(node!.creationLocation!),
      text: text,
      rect: (x: box[0]!, y: box[1]!, w: box[2]!, h: box[3]!),
      measured: measured,
    ));
  }
  return out;
}

String _place(CreationLocation l) {
  var file = l.file;
  final lib = file.lastIndexOf('/lib/');
  if (lib >= 0) file = file.substring(lib + 1);
  return '$file:${l.line}';
}
