import 'dart:async';

import 'flutter_runtime.dart';
import 'vm_service_runtime.dart';

/// The service extension the agent registers; the version suffix makes a newer glint install its own beside an older one.
const String kAgentExtension = 'ext.flutter.glintAgent7';

/// The Flutter library the agent is compiled in: it sees the binding, gestures, focus, editing and `characters`.
const String _agentLibrary = 'widgets/editable_text.dart';

/// Lifecycle changes the agent posts on the Extension stream.
const String kAgentLifecycleEvent = 'glint.lifecycle';

/// glint's helper inside the app, installed once per isolate by one eval: input, settle and lifecycle each become one service-extension call with nothing to compile.
class AppAgent {
  AppAgent._(this.runtime);

  static final _agents = Expando<AppAgent>();

  /// The agent for [runtime]; null for runtimes that cannot call service extensions.
  static AppAgent? of(FlutterRuntime runtime) =>
      runtime is VmServiceRuntime ? (_agents[runtime] ??= AppAgent._(runtime)) : null;

  final VmServiceRuntime runtime;
  String? _installedIn;

  /// Whether the app draws each touch; put back whenever the agent installs into a fresh isolate (attach, hot restart).
  bool showTouches = false;

  /// Whether the overlay draws only the touches glint itself sends through the app, because the device already draws every real touch.
  bool ownTouchesOnly = false;

  /// Turns the touch overlay on or off: `{on}`, plus `reason` (`notDebug`) when it could not be drawn.
  Future<Map<String, Object?>> setTouches(bool on, {bool ownOnly = false}) {
    showTouches = on;
    ownTouchesOnly = ownOnly;
    return call({'op': 'touches', 'on': '$on', 'own': '$ownOnly'});
  }

  /// Calls the agent with [args], installing it first in a fresh isolate (after attach or a hot restart).
  Future<Map<String, Object?>> call(Map<String, String> args, {Duration? timeout}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_installedIn != runtime.flutterIsolateId) await _install();
      final reply = await runtime.callExtensionOrNull(kAgentExtension, args, timeout: timeout);
      if (reply != null) return reply;
      _installedIn = null;
    }
    throw RuntimeEvalError(kAgentExtension, 'the in-app agent did not register');
  }

  /// Installs the agent and puts back [showTouches]; an agent already present may still draw touches for an earlier glint, so it hears the setting too.
  Future<void> _install() async {
    final isolate = runtime.flutterIsolateId;
    final r = await runtime.evaluateIn(_source.replaceAll('\n', ' '), librarySuffix: _agentLibrary);
    final status = r.valueAsString;
    if (status != 'installed' && status != 'present') {
      throw RuntimeEvalError(kAgentExtension, 'install replied ${status ?? r.kind}');
    }
    _installedIn = isolate;
    if (!showTouches && status != 'present') return;
    try {
      await runtime
          .callExtensionOrNull(kAgentExtension, {'op': 'touches', 'on': '$showTouches', 'own': '$ownTouchesOnly'});
    } on Object {
      // best-effort: touches never block input or settle; setTouches reports its own failures
    }
  }

  /// Lifecycle states the agent posts, as the app sees them (`resumed`, `inactive`, ...).
  Stream<String> get lifecycle => runtime.extensionEvents
      .where((e) => e.extensionKind == kAgentLifecycleEvent)
      .map((e) => '${e.extensionData?.data['state']}');
}

/// The agent's source. Returns `installed`, or `present` when this isolate already has it.
const String _source = r'''
(() {
  final b = WidgetsBinding.instance;
  var lastBuild = DateTime.now().millisecondsSinceEpoch;
  bool routeMoving() {
    var moving = false;
    void visit(Element e) {
      if (moving) return;
      if (e.widget.runtimeType.toString().startsWith('_ModalScope')) {
        final route = (e.widget as dynamic).route;
        for (final a in [route.animation, route.secondaryAnimation]) {
          final status = a?.status.toString() ?? '';
          if (status.endsWith('forward') || status.endsWith('reverse')) moving = true;
        }
      }
      e.visitChildren(visit);
    }
    b.rootElement?.visitChildren(visit);
    return moving;
  }
  bool covered() { final l = b.lifecycleState; return l != null && l != AppLifecycleState.resumed; }
  EditableTextState? field() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>();
  String? editable() {
    if (covered()) return 'systemSurface';
    final s = field();
    if (s == null) return 'noFocus';
    if (s.widget.readOnly) return 'readOnly';
    return null;
  }
  void put(String c) {
    final s = field();
    if (s == null) throw 'focus left the field';
    final v = s.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    if (c == '\n' && s.widget.maxLines == 1) { s.performAction(s.widget.textInputAction ?? TextInputAction.done); return; }
    s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, c), selection: TextSelection.collapsed(offset: sel.start + c.length)));
  }
  void edit(String key) {
    final s = field();
    if (s == null) throw 'focus left the field';
    final v = s.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final before = v.text.substring(0, sel.start).characters;
    final after = v.text.substring(sel.end).characters;
    switch (key) {
      case 'backspace':
        final cut = sel.isCollapsed ? before.skipLast(1).toString().length : sel.start;
        s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(cut, sel.end, ''), selection: TextSelection.collapsed(offset: cut)));
      case 'delete':
        final end = sel.isCollapsed ? sel.end + (after.isEmpty ? 0 : after.first.length) : sel.end;
        s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, end, ''), selection: TextSelection.collapsed(offset: sel.start)));
      case 'left':
        s.updateEditingValue(v.copyWith(selection: TextSelection.collapsed(offset: sel.isCollapsed ? before.skipLast(1).toString().length : sel.start)));
      case 'right':
        s.updateEditingValue(v.copyWith(selection: TextSelection.collapsed(offset: sel.isCollapsed ? sel.end + (after.isEmpty ? 0 : after.first.length) : sel.end)));
      case 'space':
        put(' ');
      case 'enter':
        put('\n');
    }
  }
  var touchesOn = false;
  var ownOnly = false;
  final own = <int>{};
  var ticking = false;
  final clock = Stopwatch()..start();
  final fingers = <int, List<List<double>>>{};
  final fingerViews = <int, int>{};
  final ripples = <List<double>>[];
  const ringMs = 280.0;
  const trailMs = 140.0;
  const radius = 15.0;
  void repaint() { for (final v in b.renderViews) { v.markNeedsPaint(); } }
  void tick(Duration _) {
    ticking = false;
    if (!touchesOn) return;
    final now = clock.elapsedMilliseconds.toDouble();
    ripples.removeWhere((r) => now - r[2] >= ringMs);
    for (final t in fingers.values) {
      while (t.length > 1 && now - t.first[2] > trailMs) { t.removeAt(0); }
    }
    repaint();
    if (ripples.isNotEmpty || fingers.values.any((t) => t.length > 1)) { ticking = true; SchedulerBinding.instance.scheduleFrameCallback(tick); }
  }
  void onPointer(PointerEvent e) {
    if (ownOnly && !own.contains(e.pointer)) return;
    final now = clock.elapsedMilliseconds.toDouble();
    final at = [e.position.dx, e.position.dy, now];
    if (e is PointerDownEvent) {
      fingers[e.pointer] = [at];
      fingerViews[e.pointer] = e.viewId;
    } else if (e is PointerMoveEvent) {
      final t = fingers[e.pointer];
      if (t == null) return;
      t.add(at);
      if (t.length > 40) t.removeAt(0);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      final view = fingerViews.remove(e.pointer);
      if (fingers.remove(e.pointer) == null) return;
      if (e is PointerUpEvent) ripples.add([e.position.dx, e.position.dy, now, (view ?? e.viewId).toDouble()]);
    } else {
      return;
    }
    repaint();
    if (!ticking) { ticking = true; SchedulerBinding.instance.scheduleFrameCallback(tick); }
  }
  void finger(Canvas c, Offset at, double a, double scale) {
    final r = radius * scale;
    c.drawCircle(at, r + 2, Paint()..color = Color.fromRGBO(4, 102, 200, 0.28 * a)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawCircle(at, r, Paint()..color = Color.fromRGBO(255, 255, 255, 0.85 * a));
    c.drawCircle(at, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = Color.fromRGBO(4, 102, 200, a));
  }
  void paintTouches(PaintingContext context, Offset offset, RenderView view) {
    if (fingers.isEmpty && ripples.isEmpty) return;
    final id = view.flutterView.viewId.toDouble();
    final c = context.canvas;
    final now = clock.elapsedMilliseconds.toDouble();
    for (final r in ripples) {
      if (r[3] != id) continue;
      final k = ((now - r[2]) / ringMs).clamp(0.0, 1.0);
      final grow = 1 - (1 - k) * (1 - k) * (1 - k);
      final at = offset + Offset(r[0], r[1]);
      c.drawCircle(at, radius * (1 + 1.6 * grow), Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = Color.fromRGBO(4, 102, 200, 0.9 * (1 - k)));
      finger(c, at, 1 - k, 1);
    }
    for (final f in fingers.entries) {
      if (fingerViews[f.key] != view.flutterView.viewId) continue;
      final t = f.value;
      if (t.length > 1) {
        final path = Path()..moveTo(offset.dx + t.first[0], offset.dy + t.first[1]);
        for (final q in t.skip(1)) { path.lineTo(offset.dx + q[0], offset.dy + q[1]); }
        c.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = radius * 1.1..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..color = Color.fromRGBO(4, 102, 200, 0.4));
      }
      finger(c, offset + Offset(t.last[0], t.last[1]), 1, 0.92);
    }
  }
  Future<Map<String, dynamic>> handle(Map<String, String> p) async {
    final op = p['op'];
    if (op == 'lifecycle') return {'state': b.lifecycleState?.name ?? 'resumed'};
    if (op == 'settle') {
      final quietMs = int.parse(p['quietMs'] ?? '100');
      final floorMs = int.parse(p['floorMs'] ?? '300');
      final ceilingMs = int.parse(p['ceilingMs'] ?? '1500');
      final start = DateTime.now().millisecondsSinceEpoch;
      while (true) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsed = now - start;
        final sinceBuild = now - (lastBuild > start ? lastBuild : start);
        final calm = b.schedulerPhase == SchedulerPhase.idle && (sinceBuild >= quietMs || elapsed >= floorMs);
        if (calm && !routeMoving()) return {'status': 'settled', 'ms': elapsed};
        if (elapsed >= ceilingMs) return {'status': 'animating', 'ms': elapsed};
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    if (op == 'touch') {
      if (covered()) return {'status': 'systemSurface'};
      final view = b.platformDispatcher.implicitView;
      if (view == null) return {'status': 'outside'};
      final pts = [for (final s in p['pts']!.split(';')) [for (final v in s.split(',')) double.parse(v)]];
      final dpr = view.devicePixelRatio;
      final size = view.physicalSize / dpr;
      final first = Offset(pts[0][0], pts[0][1]);
      if (first.dx < 0 || first.dy < 0 || first.dx > size.width || first.dy > size.height) return {'status': 'outside'};
      if (view.viewInsets.bottom > 0 && first.dy > size.height - view.viewInsets.bottom / dpr) return {'status': 'keyboard'};
      final hit = HitTestResult();
      b.hitTestInView(hit, first, view.viewId);
      if (hit.path.any((e) { final t = e.target.runtimeType.toString(); return t.contains('UiKitView') || t.contains('AppKitView') || t.contains('AndroidView') || t.contains('PlatformView'); })) return {'status': 'platformView'};
      final pointer = int.parse(p['pointer']!);
      own.add(pointer);
      final t0 = DateTime.now().microsecondsSinceEpoch;
      final clock = Stopwatch()..start();
      Duration at(double ms) => Duration(microseconds: t0 + (ms * 1000).round());
      for (var i = 0; i < pts.length; i++) {
        final q = pts[i];
        final wait = q[2] - clock.elapsedMicroseconds / 1000;
        if (wait > 0) await Future<void>.delayed(Duration(microseconds: (wait * 1000).round()));
        final pos = Offset(q[0], q[1]);
        if (i == 0) {
          b.handlePointerEvent(PointerDownEvent(viewId: view.viewId, pointer: pointer, kind: PointerDeviceKind.touch, position: pos, timeStamp: at(0)));
        } else {
          final prev = Offset(pts[i - 1][0], pts[i - 1][1]);
          if (pos != prev) b.handlePointerEvent(PointerMoveEvent(viewId: view.viewId, pointer: pointer, kind: PointerDeviceKind.touch, position: pos, delta: pos - prev, timeStamp: at(q[2])));
        }
        if (i == pts.length - 1) b.handlePointerEvent(PointerUpEvent(viewId: view.viewId, pointer: pointer, kind: PointerDeviceKind.touch, position: pos, timeStamp: at(q[2])));
      }
      own.remove(pointer);
      return {'status': 'ok'};
    }
    if (op == 'pinch') {
      if (covered()) return {'status': 'systemSurface'};
      final view = b.platformDispatcher.implicitView;
      if (view == null) return {'status': 'outside'};
      final cx = double.parse(p['cx']!);
      final cy = double.parse(p['cy']!);
      final from = double.parse(p['from']!);
      final to = double.parse(p['to']!);
      final ms = int.parse(p['ms'] ?? '400');
      final base = int.parse(p['pointer']!);
      own.addAll([base, base + 1]);
      final steps = ms ~/ 16 < 3 ? 3 : ms ~/ 16;
      final t0 = DateTime.now().microsecondsSinceEpoch;
      Offset at(int finger, double span) => Offset(cx + (finger == 0 ? -span / 2 : span / 2), cy);
      for (var finger = 0; finger < 2; finger++) {
        b.handlePointerEvent(PointerDownEvent(viewId: view.viewId, pointer: base + finger, kind: PointerDeviceKind.touch, position: at(finger, from), timeStamp: Duration(microseconds: t0)));
      }
      var prev = from;
      for (var i = 1; i <= steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final span = from + (to - from) * i / steps;
        final stamp = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
        for (var finger = 0; finger < 2; finger++) {
          final pos = at(finger, span);
          b.handlePointerEvent(PointerMoveEvent(viewId: view.viewId, pointer: base + finger, kind: PointerDeviceKind.touch, position: pos, delta: pos - at(finger, prev), timeStamp: stamp));
        }
        prev = span;
      }
      final end = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
      for (var finger = 0; finger < 2; finger++) {
        b.handlePointerEvent(PointerUpEvent(viewId: view.viewId, pointer: base + finger, kind: PointerDeviceKind.touch, position: at(finger, to), timeStamp: end));
      }
      own.removeAll([base, base + 1]);
      return {'status': 'ok'};
    }
    if (op == 'touches') {
      final want = p['on'] == 'true';
      ownOnly = p['own'] == 'true';
      if (want == touchesOn) return {'on': touchesOn};
      if (want) {
        var asserts = false;
        assert(() { asserts = true; return true; }());
        if (!asserts) return {'on': false, 'reason': 'notDebug'};
        b.pointerRouter.addGlobalRoute(onPointer);
        RenderView.debugAddPaintCallback(paintTouches);
        touchesOn = true;
      } else {
        b.pointerRouter.removeGlobalRoute(onPointer);
        RenderView.debugRemovePaintCallback(paintTouches);
        touchesOn = false;
        fingers.clear();
        fingerViews.clear();
        ripples.clear();
      }
      repaint();
      return {'on': touchesOn};
    }
    if (op == 'awaitBuild') {
      final windowMs = int.parse(p['ms'] ?? '1500');
      final start = DateTime.now().millisecondsSinceEpoch;
      while (DateTime.now().millisecondsSinceEpoch - start < windowMs) {
        if (lastBuild > start) return {'built': true, 'ms': lastBuild - start};
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return {'built': false, 'ms': windowMs};
    }
    final miss = editable();
    if (miss != null) return {'status': miss};
    if (op == 'type') {
      final cs = p['text']!.characters.toList();
      final gap = int.parse(p['gapMs'] ?? '0');
      for (var i = 0; i < cs.length; i++) {
        try {
          put(cs[i]);
        } catch (e) {
          return {'status': 'partial', 'delivered': i, 'of': cs.length, 'error': '$e'};
        }
        if (gap > 0 && i < cs.length - 1) await Future<void>.delayed(Duration(milliseconds: gap));
      }
      return {'status': 'ok'};
    }
    if (op == 'key') {
      final count = int.parse(p['count'] ?? '1');
      for (var i = 0; i < count; i++) {
        try {
          edit(p['key']!);
        } catch (e) {
          return {'status': 'partial', 'delivered': i, 'of': count, 'error': '$e'};
        }
      }
      return {'status': 'ok'};
    }
    if (op == 'selectAll') {
      field()!.selectAll(SelectionChangedCause.keyboard);
      return {'status': 'ok'};
    }
    return {'status': 'unknownOp'};
  }
  try {
    b.registerServiceExtension(name: 'glintAgent7', callback: handle);
  } catch (e) {
    return 'present';
  }
  final owner = b.buildOwner!;
  final scheduled = owner.onBuildScheduled;
  owner.onBuildScheduled = () { lastBuild = DateTime.now().millisecondsSinceEpoch; scheduled?.call(); };
  AppLifecycleListener(onStateChange: (s) => b.postEvent('glint.lifecycle', {'state': s.name}));
  return 'installed';
})()
''';
