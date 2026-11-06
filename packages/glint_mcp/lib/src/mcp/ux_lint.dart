import 'dart:async';

import '../../interaction.dart' show GlintErrorKind;
import '../../perception.dart' show SceneNode;
import '../../semantic.dart' show SemanticScene;
import '../runtime/flutter_runtime.dart';
import 'watch_conditions.dart';
import 'watch_observation.dart';

/// Cheap layout signature: insets, view size, box sizes, paragraph count, scroll offsets and a sample of box positions.
final String lintProbeExpr = _probeSource.replaceAll('@@HELPERS@@', _helpers).replaceAll('\n', ' ');

/// Shared by the probe and the walk: `kids` skips overlay entries covered by an opaque route, `hidden` skips invisible subtrees.
const String _helpers = r'''
  List<dynamic> kids(dynamic r) {
    final out = <dynamic>[];
    if (r.runtimeType.toString() == '_RenderTheater') {
      try {
        var skip = r.skipCount as int;
        dynamic c = r.firstChild;
        while (c != null) {
          final pd = c.parentData as dynamic;
          if (skip > 0) {
            skip--;
          } else {
            out.add(c);
            pd.visitOverlayPortalChildrenOnOverlayEntry(out.add);
          }
          c = pd.nextSibling;
        }
        return out;
      } catch (_) {
        out.clear();
      }
    }
    r.visitChildren(out.add);
    return out;
  }
  bool hidden(dynamic r, String t) {
    if (t == 'RenderOffstage' && r.offstage == true) return true;
    if (t == 'RenderOpacity' && r.opacity == 0) return true;
    if (t == 'RenderAnimatedOpacity') {
      try { if (r.opacity.value == 0) return true; } catch (_) {}
    }
    return false;
  }
''';

const String _probeSource = r'''
(() {
  @@HELPERS@@
  final m = 0x3fffffff;
  var h = 0;
  var s = '';
  var paragraphs = 0;
  var boxes = 0;
  var sampled = 0;
  void mix(int v) {
    h = (h * 31 + v) & m;
  }
  for (final rv in RendererBinding.instance.renderViews) {
    final fv = rv.flutterView;
    final d = fv.devicePixelRatio;
    s += (fv.viewInsets.bottom / d).toStringAsFixed(1) + ',' + (fv.viewPadding.top / d).toStringAsFixed(1) + ',' + (fv.viewPadding.bottom / d).toStringAsFixed(1) + ',' + fv.physicalSize.width.toString() + 'x' + fv.physicalSize.height.toString() + ';';
    void w(dynamic o) {
      final t = o.runtimeType.toString();
      if (hidden(o, t)) return;
      if (!t.endsWith('RenderView') && !t.startsWith('RenderSliver')) {
        try {
          if (o.hasSize) {
            mix((o.size.width * 8).round() as int);
            mix((o.size.height * 8).round() as int);
            if (t == 'RenderParagraph') paragraphs++;
            if (t == 'RenderEditable' && o.hasFocus == true) mix((o.localToGlobal(Offset.zero).dy * 4).round() as int);
            boxes++;
            if (boxes % 6 == 0 && sampled < 120) {
              sampled++;
              final g = o.localToGlobal(Offset.zero);
              mix((g.dx * 2).round() as int);
              mix((g.dy * 2).round() as int);
            }
          }
          if (t.endsWith('Viewport')) mix((o.offset.pixels * 2).round() as int);
        } catch (_) {}
      }
      for (final c in kids(o)) {
        w(c);
      }
    }
    w(rv);
  }
  return s + paragraphs.toString() + ':' + h.toString();
})()
''';

const String _walkTemplate = r'''
(() {
  @@HELPERS@@
  final svc = WidgetInspectorService.instance;
  final group = '@@GROUP@@';
  final rules = <String>{@@RULES@@};
  final minTap = @@MIN_TAP@@;
  final maxHeadline = @@MAX_LINES@@;
  final out = <String>[];
  final counts = <String, int>{};
  final stack = <int>[];
  var errors = 0;
  var firstError = '';
  String n(double v) => v.toStringAsFixed(1);
  String clean(String s, [int max = 50]) {
    final t = s.replaceAll('\n', ' ').replaceAll('|', ' ').replaceAll(';', ' ').replaceAll('=', ' ').replaceAll(',', ' ').trim();
    return t.length > max ? t.substring(0, max - 1) : t;
  }
  void note(String where, Object e) {
    errors++;
    if (firstError.isEmpty) firstError = clean(where + ': ' + e.toString(), 160);
  }
  String creation(dynamic el) {
    final json = el.toDiagnosticsNode().toJsonMap(InspectorSerializationDelegate(service: svc, subtreeDepth: 0)) as Map;
    final at = json['creationLocation'];
    if (json['createdByLocalProject'] != true || at == null) return '';
    return at['file'].toString() + ':' + at['line'].toString();
  }
  void add(String rule, dynamic r, double x, double y, double w, double h, String detail) {
    final c = counts[rule] ?? 0;
    counts[rule] = c + 1;
    if (c >= 15) return;
    final ids = <String>[];
    var loc = '';
    try {
      final el = (r.debugCreator as dynamic).element;
      ids.add(svc.toId(el, group)!);
      loc = creation(el);
      el.visitAncestorElements((a) {
        ids.add(svc.toId(a, group)!);
        if (loc.isEmpty) loc = creation(a);
        return ids.length < 40;
      });
    } catch (e) { note(rule + ' ids', e); }
    out.add('F|' + rule + '|' + r.runtimeType.toString() + '|' + n(x) + ',' + n(y) + ',' + n(w) + ',' + n(h) + '|' + detail + '|' + (stack.length > 4 ? stack.sublist(stack.length - 4) : stack).join('.') + '|' + ids.join(',') + '|' + loc);
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
    try { return RenderAbstractViewport.maybeOf(r) != null; } catch (e) { note('viewport', e); return false; }
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
      if (t.endsWith('RenderView') || t.startsWith('RenderSliver') || !r.hasSize) return;
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
          } catch (e) { note('keyboard caret', e); }
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
          add('clippedText', r, x, y, w, h, 'maxLines=' + r.maxLines.toString() + ';overflow=' + (r.overflow.toString().split('.').last) + ';text=' + text);
        }
        if (rules.contains('lines')) {
          var fs = 0.0;
          try { fs = (r.text.style?.fontSize ?? 0.0) as double; } catch (e) { note('fontSize', e); }
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
      if (hidden(r, t)) return;
      try { visit(r, t); } catch (e) { note(t, e); }
      final c = kids(r);
      for (var i = 0; i < c.length; i++) {
        stack.add(i);
        walk(c[i]);
        stack.removeLast();
      }
    }
    walk(rv);
  }
  for (final e in counts.entries) {
    if (e.value > 15) out.add('C|' + e.key + '|' + (e.value - 15).toString());
  }
  if (errors > 0) out.add('E|' + errors.toString() + '|' + firstError);
  return out.join('\n');
})()
''';

/// The one-walk lint expression for [spec], registering ancestors in inspector group [group].
String lintWalkExpr(LintCondition spec, String group) => _walkTemplate
    .replaceAll('@@HELPERS@@', _helpers)
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
    this.path = '',
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

  /// Child indexes of the last few render levels, which tell apart problems under one scene node and survive scrolling.
  final String path;
  final ({double x, double y, double w, double h}) rect;
  final Map<String, Object?> measured;

  /// What identifies the same problem again: rule, widget and the numbers that make it that problem.
  String get key {
    final id = glintId ?? '$widget@${rect.w.round()}x${rect.h.round()}';
    final detail = switch (rule) {
      'clippedText' || 'lines' => text ?? '',
      'tapTarget' => '${rect.w.round()}x${rect.h.round()}',
      _ => '${measured['edge'] ?? ''}|$path',
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

/// Why a lint check could not run: an `errorKind`, the reason and what to do next.
class LintProblem {
  const LintProblem({
    required this.errorKind,
    required this.detail,
    required this.nextSteps,
    required this.retrying,
    this.partial = false,
  });

  final GlintErrorKind errorKind;
  final String detail;
  final List<String> nextSteps;
  final bool retrying;

  /// The check still ran and reported what it could; some node checks threw.
  final bool partial;
}

void _nothingToCommit() {}

/// What one lint tick produced: findings new since the last check, how many the walk could not list per rule, or why the check cannot run; [commit] records the findings as reported once they are written.
class LintOutcome {
  const LintOutcome({
    this.fresh = const [],
    this.hidden = const {},
    this.problem,
    this.commit = _nothingToCommit,
  });

  static const none = LintOutcome();

  final List<LintFinding> fresh;
  final Map<String, int> hidden;
  final LintProblem? problem;
  final void Function() commit;
}

class _NoReply implements Exception {
  _NoReply(this.what);

  final String what;
}

/// Runs the lint rules of one `{lint}` condition: waits for the screen to settle, walks the render tree once, and reports only what is new.
class LintWatcher {
  LintWatcher(this.spec);

  static const _maxUnsettledTicks = 8;
  static const _maxFreshPerCheck = 12;
  static const _maxTransient = 5;
  static const _backoffTicks = 20;

  /// How long one walk may take before the check is given up for this tick.
  static const walkLimit = Duration(seconds: 20);

  final LintCondition spec;
  String? _lastSignature;
  String? _checkedSignature;
  int _unsettled = 0;
  int _transient = 0;
  int _pausedTicks = 0;
  bool _reported = false;
  bool _busy = false;
  String? _route;
  String? _reportedWalkError;
  final Map<String, Set<String>> _fired = {};

  /// Whether the eval failed to compile; the condition then stays quiet.
  bool disabled = false;

  /// One tick: the first one checks at once, later ones only after the layout signature changed and then held still for a tick; [probe] is the app's shared layout probe for this read.
  Future<LintOutcome> tick(
    FlutterRuntime runtime,
    SemanticScene scene,
    WatchObservation obs,
    Future<String?> probe,
  ) async {
    if (disabled) return LintOutcome.none;
    _enterRoute(obs.route);
    if (_busy) return LintOutcome.none;
    if (_pausedTicks > 0) {
      _pausedTicks--;
      return LintOutcome.none;
    }
    _busy = true;
    try {
      final outcome = await _check(runtime, scene, obs, probe);
      _transient = 0;
      _reported = false;
      return outcome;
    } on _NoReply catch (e) {
      return _transientFailure(e.what, GlintErrorKind.appBusy);
    } on RuntimeEvalError catch (e) {
      if (_isCompileError(e.message)) return _compileFailure(e.message);
      return _transientFailure(_firstLine(e.message), GlintErrorKind.appBusy);
    } on RuntimeConnectionLostError {
      return _transientFailure('the connection to the app dropped', GlintErrorKind.connectionLost);
    } on TimeoutException {
      return _transientFailure('the app did not answer the layout check in time', GlintErrorKind.appBusy);
    } on RuntimeUnresponsiveError {
      return _transientFailure('the app did not answer the layout check in time', GlintErrorKind.appBusy);
    } on Object catch (e) {
      return _transientFailure(_firstLine('$e'), GlintErrorKind.internal);
    } finally {
      _busy = false;
    }
  }

  /// Leaving a route forgets what fired on it, so coming back reports its problems again.
  void _enterRoute(String route) {
    if (_route == route) return;
    if (_route != null) _fired.remove(_route);
    _checkedSignature = null;
    _route = route;
  }

  Future<LintOutcome> _check(
    FlutterRuntime runtime,
    SemanticScene scene,
    WatchObservation obs,
    Future<String?> probe,
  ) async {
    final shape = await probe;
    if (shape == null) throw _NoReply('the layout probe returned no string');
    final signature = '$shape|${obs.route}|${obs.overlay}|${Object.hashAllUnordered(obs.tappableIds)}';
    if (signature == _checkedSignature) {
      _lastSignature = signature;
      _unsettled = 0;
      return LintOutcome.none;
    }
    final first = _lastSignature == null;
    if (signature != _lastSignature) {
      _lastSignature = signature;
      _unsettled++;
      if (!first && _unsettled < _maxUnsettledTicks) return LintOutcome.none;
    }
    _unsettled = 0;
    final raw = await runtime
        .evaluateString(lintWalkExpr(spec, scene.sourceScene.groupName), rethrowErrors: true)
        .timeout(walkLimit);
    if (raw == null) throw _NoReply('the lint walk returned no string');
    final found = parseLintFindings(raw, scene.sourceScene.root, obs.route);
    return _outcome(found, parseLintHidden(raw), parseLintWalkError(raw), obs.route, signature);
  }

  LintOutcome _outcome(
    List<LintFinding> found,
    Map<String, int> hidden,
    ({int count, String message})? walkError,
    String route,
    String signature,
  ) {
    final held = _fired[route] ?? <String>{};
    final current = {for (final f in found) f.key};
    final fresh = <LintFinding>[];
    final emitted = <String>{};
    final deferred = <String>{};
    for (final f in found) {
      if (held.contains(f.key) || emitted.contains(f.key) || deferred.contains(f.key)) continue;
      if (fresh.length >= _maxFreshPerCheck) {
        deferred.add(f.key);
        continue;
      }
      emitted.add(f.key);
      fresh.add(f);
    }
    return LintOutcome(
      fresh: fresh,
      hidden: hidden,
      problem: _walkProblem(walkError),
      commit: () {
        _fired[route] = {...held.intersection(current), ...emitted};
        if (deferred.isEmpty) _checkedSignature = signature;
      },
    );
  }

  LintProblem? _walkProblem(({int count, String message})? error) {
    if (error == null || error.message == _reportedWalkError) return null;
    _reportedWalkError = error.message;
    return LintProblem(
      errorKind: GlintErrorKind.internal,
      detail: '${error.count} node checks threw during the lint walk, first: ${error.message}',
      nextSteps: const [
        'findings from the nodes that did work still arrive; a rule may be blind on some widgets',
        'report_issue with this detail and the Flutter version',
      ],
      retrying: true,
      partial: true,
    );
  }

  LintOutcome _compileFailure(String message) {
    disabled = true;
    final text = message.length > 400 ? '${message.substring(0, 399)}…' : message;
    return LintOutcome(
      problem: LintProblem(
        errorKind: GlintErrorKind.internal,
        detail: 'the lint expression did not compile in this app: $text',
        nextSteps: const [
          'lint is off for this watch for good; the other conditions keep running',
          'report_issue with this detail and the Flutter version, and use get_scene meanwhile',
        ],
        retrying: false,
      ),
    );
  }

  LintOutcome _transientFailure(String reason, GlintErrorKind kind) {
    _transient++;
    if (_transient < _maxTransient) return LintOutcome.none;
    _pausedTicks = _backoffTicks;
    if (_reported) return LintOutcome.none;
    _reported = true;
    return LintOutcome(
      problem: LintProblem(
        errorKind: kind,
        detail: '$reason ($_maxTransient checks in a row)',
        nextSteps: const [
          'glint keeps retrying about every 30 s and stays quiet until a check works',
          'get_scene to see whether the app is reloading, locked or busy',
          'watch op:cancel if you no longer need lint',
        ],
        retrying: true,
      ),
    );
  }

  static bool _isCompileError(String message) {
    final lower = message.toLowerCase();
    return lower.startsWith('rpcerror(113)') || lower.contains('compilation error');
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first;
    return line.length > 200 ? '${line.substring(0, 199)}…' : line;
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
    if (parts.length < 7 || parts.first != 'F') continue;
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
    final place = parts.length > 7 ? parts[7] : '';
    SceneNode? node;
    for (final id in parts[6].split(',')) {
      node = byInspector[id];
      if (node != null) break;
    }
    out.add(LintFinding(
      rule: parts[1],
      route: route,
      widget: node?.baseLabel ?? parts[2],
      glintId: node?.glintId,
      location: place.isEmpty ? null : _place(place),
      text: text,
      path: parts[5],
      rect: (x: box[0]!, y: box[1]!, w: box[2]!, h: box[3]!),
      measured: measured,
    ));
  }
  return out;
}

/// Per rule, how many problems the walk found past its per-rule listing cap.
Map<String, int> parseLintHidden(String raw) {
  final out = <String, int>{};
  for (final line in raw.split('\n')) {
    final parts = line.split('|');
    if (parts.length != 3 || parts.first != 'C') continue;
    final count = int.tryParse(parts[2]);
    if (count != null) out[parts[1]] = count;
  }
  return out;
}

/// A creation `file:line` shortened to start at `lib/` when the file is under one.
String _place(String fileAndLine) {
  final lib = fileAndLine.lastIndexOf('/lib/');
  return lib >= 0 ? fileAndLine.substring(lib + 1) : fileAndLine;
}

/// How many node checks threw in a lint walk and the first message, or null when none did.
({int count, String message})? parseLintWalkError(String raw) {
  for (final line in raw.split('\n')) {
    final parts = line.split('|');
    if (parts.length < 3 || parts.first != 'E') continue;
    final count = int.tryParse(parts[1]);
    if (count != null) return (count: count, message: parts.sublist(2).join('|'));
  }
  return null;
}
