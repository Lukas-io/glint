import 'dart:convert';

import '../runtime/flutter_runtime.dart';

/// Why Flutter could not take an input itself; the caller hands it to the platform instead.
enum FlutterInputMiss {
  systemSurface('a system surface (alert, sheet, permission prompt) is over the app'),
  keyboard('the point is on the on-screen keyboard'),
  platformView('the point is on a native view embedded in the app'),
  outside('the point is outside the app'),
  noFocus('no Flutter text field has focus'),
  readOnly('the focused field is read-only'),
  partial('only part of the input landed'),
  unsupportedKey('the key has no Flutter text-editing equivalent'),
  evalFailed('the app did not answer the input eval');

  const FlutterInputMiss(this.reason);
  final String reason;
}

/// Input delivered inside the app through the VM service: pointer events into GestureBinding, edits into the focused EditableText.
class FlutterInput {
  FlutterInput(this.runtime);

  final FlutterRuntime runtime;

  static var _nextPointer = 0x7A000;
  static const _gestures = 'package:flutter/src/widgets/binding.dart';
  static const _editing = 'package:flutter/src/widgets/editable_text.dart';

  /// Sends one touch through [points] (logical x, y, ms after the first); null when it was delivered.
  Future<FlutterInputMiss?> touch(List<({double x, double y, int ms})> points) async {
    final pointer = _nextPointer++;
    final pts = points.map((p) => '[${p.x}, ${p.y}, ${p.ms}]').join(', ');
    final miss = await _eval(_gestures, '''(() {
      final b = WidgetsBinding.instance;
      final view = b.platformDispatcher.implicitView;
      if (view == null) return 'outside';
      final life = b.lifecycleState;
      if (life != null && life != AppLifecycleState.resumed) return 'systemSurface';
      final pts = <List<num>>[$pts];
      final dpr = view.devicePixelRatio;
      final size = view.physicalSize / dpr;
      final first = Offset(pts[0][0].toDouble(), pts[0][1].toDouble());
      if (first.dx < 0 || first.dy < 0 || first.dx > size.width || first.dy > size.height) return 'outside';
      if (view.viewInsets.bottom > 0 && first.dy > size.height - view.viewInsets.bottom / dpr) return 'keyboard';
      final hit = HitTestResult();
      b.hitTestInView(hit, first, view.viewId);
      if (hit.path.any((e) { final t = e.target.runtimeType.toString(); return t.contains('UiKitView') || t.contains('AppKitView') || t.contains('AndroidView') || t.contains('PlatformView'); })) return 'platformView';
      final t0 = DateTime.now().microsecondsSinceEpoch;
      Duration at(num ms) => Duration(microseconds: t0 + (ms * 1000).round());
      void send(int i) {
        final q = pts[i];
        final pos = Offset(q[0].toDouble(), q[1].toDouble());
        if (i == 0) {
          b.handlePointerEvent(PointerDownEvent(viewId: view.viewId, pointer: $pointer, kind: PointerDeviceKind.touch, position: pos, timeStamp: at(0)));
        } else {
          final prev = Offset(pts[i - 1][0].toDouble(), pts[i - 1][1].toDouble());
          if (pos != prev) b.handlePointerEvent(PointerMoveEvent(viewId: view.viewId, pointer: $pointer, kind: PointerDeviceKind.touch, position: pos, delta: pos - prev, timeStamp: at(q[2])));
        }
        if (i == pts.length - 1) b.handlePointerEvent(PointerUpEvent(viewId: view.viewId, pointer: $pointer, kind: PointerDeviceKind.touch, position: pos, timeStamp: at(q[2])));
      }
      send(0);
      for (var i = 1; i < pts.length; i++) {
        final j = i;
        Timer(Duration(microseconds: (pts[j][2] * 1000).round()), () => send(j));
      }
      return 'ok';
    })()''');
    if (miss == null) await Future<void>.delayed(Duration(milliseconds: points.last.ms + 20));
    return miss;
  }

  /// Types [text] into the focused Flutter field, one character per edit so formatters see each keystroke; null when delivered.
  Future<FlutterInputMiss?> type(String text, {int gapMs = 0}) async {
    final miss = await _eval(_editing, '''(() {
      ${_focused()}
      final cs = ${jsonEncode(text).replaceAll(r'$', r'\$')}.characters.toList();
      void put(String c) {
        final s = current();
        if (s == null) throw 'focus left the field';
        final v = s.textEditingValue;
        final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
        if (c == '\\n' && s.widget.maxLines == 1) {
          s.performAction(s.widget.textInputAction ?? TextInputAction.done);
          return;
        }
        s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, c), selection: TextSelection.collapsed(offset: sel.start + c.length)));
      }
      if ($gapMs == 0) {
        var n = 0;
        try {
          for (final c in cs) {
            put(c);
            n++;
          }
        } catch (e) {
          return 'partial:\$n:\${cs.length}:\$e';
        }
      } else {
        for (var i = 0; i < cs.length; i++) {
          final c = cs[i];
          Timer(Duration(milliseconds: $gapMs * i), () => put(c));
        }
      }
      return 'ok';
    })()''');
    if (miss == null && gapMs > 0) await Future<void>.delayed(Duration(milliseconds: gapMs * text.length + 20));
    return miss;
  }

  /// Presses an editing key ([key] is a `KeyName` name) [count] times in the focused Flutter field; null when delivered.
  Future<FlutterInputMiss?> key(String key, {int count = 1}) async {
    const edits = {
      'backspace': 'final cut = sel.isCollapsed ? v.text.substring(0, sel.start).characters.skipLast(1).toString().length : sel.start; '
          "s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(cut, sel.end, ''), selection: TextSelection.collapsed(offset: cut)));",
      'delete': 'final end = sel.isCollapsed ? sel.end + (v.text.substring(sel.end).characters.isEmpty ? 0 : v.text.substring(sel.end).characters.first.length) : sel.end; '
          "s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, end, ''), selection: TextSelection.collapsed(offset: sel.start)));",
      'left': 'final o = sel.isCollapsed ? v.text.substring(0, sel.start).characters.skipLast(1).toString().length : sel.start; '
          's.updateEditingValue(v.copyWith(selection: TextSelection.collapsed(offset: o)));',
      'right': 'final o = sel.isCollapsed ? sel.end + (v.text.substring(sel.end).characters.isEmpty ? 0 : v.text.substring(sel.end).characters.first.length) : sel.end; '
          's.updateEditingValue(v.copyWith(selection: TextSelection.collapsed(offset: o)));',
      'space': "s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, ' '), selection: TextSelection.collapsed(offset: sel.start + 1)));",
      'enter': 'if (s.widget.maxLines == 1) { s.performAction(s.widget.textInputAction ?? TextInputAction.done); } else { '
          "s.updateEditingValue(TextEditingValue(text: v.text.replaceRange(sel.start, sel.end, '\\n'), selection: TextSelection.collapsed(offset: sel.start + 1))); }",
    };
    final edit = edits[key];
    if (edit == null) return FlutterInputMiss.unsupportedKey;
    return _eval(_editing, '''(() {
      ${_focused()}
      for (var i = 0; i < $count; i++) {
        try {
          final s = current();
          if (s == null) throw 'focus left the field';
          final v = s.textEditingValue;
          final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
          $edit
        } catch (e) {
          return 'partial:\$i:$count:\$e';
        }
      }
      return 'ok';
    })()''');
  }

  /// Selects all text in the focused Flutter field; null when delivered.
  Future<FlutterInputMiss?> selectAll() => _eval(_editing, '''(() {
        ${_focused()}
        s.selectAll(SelectionChangedCause.keyboard);
        return 'ok';
      })()''');

  String _focused() => '''
      final life = WidgetsBinding.instance.lifecycleState;
      if (life != null && life != AppLifecycleState.resumed) return 'systemSurface';
      final ctx = FocusManager.instance.primaryFocus?.context;
      final s = ctx?.findAncestorStateOfType<EditableTextState>();
      if (s == null) return 'noFocus';
      if (s.widget.readOnly) return 'readOnly';
      EditableTextState? current() => FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>();''';

  /// The eval's own error after an [FlutterInputMiss.evalFailed], for the reply.
  String? lastError;

  /// How much of the last partial edit landed: `delivered` of `of`.
  ({int delivered, int of})? lastPartial;

  Future<FlutterInputMiss?> _eval(String library, String expression) async {
    lastError = null;
    lastPartial = null;
    final String? status;
    try {
      status = (await runtime.evaluateIn(expression.replaceAll('\n', ' '), librarySuffix: library)).valueAsString;
    } on Object catch (e) {
      lastError = '$e'.split('\n').firstWhere((l) => l.trim().isNotEmpty && !l.startsWith('Unhandled'), orElse: () => '$e');
      return FlutterInputMiss.evalFailed;
    }
    if (status == 'ok') return null;
    if (status != null && status.startsWith('partial:')) {
      final parts = status.split(':');
      lastPartial = (delivered: int.tryParse(parts[1]) ?? 0, of: int.tryParse(parts[2]) ?? 0);
      lastError = parts.skip(3).join(':');
      return FlutterInputMiss.partial;
    }
    final miss = FlutterInputMiss.values.where((m) => m.name == status).firstOrNull;
    if (miss == null) lastError = 'unexpected reply $status';
    return miss ?? FlutterInputMiss.evalFailed;
  }
}
