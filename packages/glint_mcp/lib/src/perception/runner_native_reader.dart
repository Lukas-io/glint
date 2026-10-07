import 'android_native_reader.dart';
import 'native_scene_reader.dart';
import 'scene_reader.dart';

/// iOS native UI read through glint's XCUITest runner: system alerts, and surfaces the app presents in-process (photo picker, edit menu) that leave the Flutter lifecycle resumed.
class RunnerNativeReader extends NativeReader {
  RunnerNativeReader({required this.tree, required this.bundleId, required this.fallback});

  /// The runner's `/tree` reply for [bundleId]; throws when the runner does not answer.
  final Future<Map<String, Object?>> Function(String? bundleId) tree;
  final String? Function() bundleId;

  /// Used when the runner finds nothing over the app, e.g. while it is backgrounded.
  final NativeReader fallback;

  List<Map<String, Object?>> _surface = const [];
  ({double w, double h})? _screen;

  @override
  Future<String?> foreignSurface() async {
    final Map<String, Object?> reply;
    try {
      reply = await tree(bundleId());
    } on Object {
      _surface = const [];
      return null;
    }
    final found = findNativeSurface(reply);
    _surface = found?.roots ?? const [];
    _screen = screenOf(reply);
    return found?.name;
  }

  @override
  Future<Scene> readSnapshot() async {
    if (_surface.isEmpty) await foreignSurface();
    if (_surface.isEmpty) return fallback.readSnapshot();
    return nativeScene(nativeElements(_surface, screen: _screen), 1);
  }
}

/// Element types UIKit draws but Flutter's accessibility bridge never produces.
const _uikitOnly = {
  'alert',
  'sheet',
  'navigationBar',
  'toolbar',
  'tabBar',
  'menu',
  'menuItem',
  'collectionView',
  'table',
  'cell',
  'pickerWheel',
  'datePicker',
  'segmentedControl',
};

const _tappable = {
  'button',
  'menuItem',
  'cell',
  'link',
  'textField',
  'secureTextField',
  'searchField',
  'textView',
  'switch',
  'toggle',
  'slider',
};

/// The keyboard is UIKit too, but it is the app's own input, not something over it.
bool _isKeyboard(Map<String, Object?> n) {
  final id = n['id'];
  return n['type'] == 'keyboard' || id == 'inputView' || id == 'SystemInputAssistantView';
}

List<Map<String, Object?>> _children(Map<String, Object?> n) =>
    [for (final c in (n['children'] as List? ?? const [])) if (c is Map) c.cast<String, Object?>()];

/// What covers the app in a runner `/tree` reply: a system alert, else the window's top-level view holding the UIKit-only elements (Flutter's own sit in another, or are hidden by a full-screen modal); null when only Flutter and the keyboard are on screen.
({String name, List<Map<String, Object?>> roots})? findNativeSurface(Map<String, Object?> reply) {
  final alerts = [for (final a in (reply['alerts'] as List? ?? const [])) if (a is Map) a.cast<String, Object?>()];
  if (alerts.isNotEmpty) {
    final label = alerts.first['label'] as String?;
    return (name: label == null || label.isEmpty ? 'a system alert' : 'alert "$label"', roots: alerts);
  }
  final app = reply['app'];
  if (app is! Map) return null;
  final paths = <List<Map<String, Object?>>>[];
  void walk(Map<String, Object?> n, List<Map<String, Object?>> path) {
    if (_isKeyboard(n)) return;
    final here = [...path, n];
    if (_uikitOnly.contains(n['type'])) paths.add(here);
    for (final c in _children(n)) {
      walk(c, here);
    }
  }

  walk(app.cast<String, Object?>(), const []);
  if (paths.isEmpty) return null;
  var common = paths.first;
  for (final p in paths.skip(1)) {
    var i = 0;
    while (i < common.length && i < p.length && identical(common[i], p[i])) {
      i++;
    }
    common = common.sublist(0, i);
  }
  final root = common[common.length < 3 ? common.length - 1 : 2];
  return (name: _surfaceName([for (final p in paths) p.last]), roots: [root]);
}

String _surfaceName(List<Map<String, Object?>> marks) {
  String? labelOf(Map<String, Object?> n) {
    for (final key in ['id', 'label']) {
      final v = n[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  final bar = marks.where((n) => n['type'] == 'navigationBar').firstOrNull;
  if (bar != null) return 'native screen "${labelOf(bar) ?? 'untitled'}"';
  final items = [for (final n in marks) if (n['type'] == 'menuItem') labelOf(n)].whereType<String>();
  if (items.isNotEmpty) return 'menu (${items.take(4).join(' · ')})';
  final first = marks.first;
  final label = labelOf(first);
  return label == null ? 'native ${first['type']}' : 'native ${first['type']} "$label"';
}

/// The app's frame size in a runner `/tree` reply, which is the screen in logical points.
({double w, double h})? screenOf(Map<String, Object?> reply) {
  final app = reply['app'];
  final f = app is Map ? app['frame'] : null;
  if (f is! List || f.length != 4) return null;
  return (w: (f[2] as num).toDouble(), h: (f[3] as num).toDouble());
}

/// The labelled or tappable elements under [roots] whose center is on [screen], in logical points, at most [max].
List<NativeNode> nativeElements(List<Map<String, Object?>> roots, {({double w, double h})? screen, int max = 40}) {
  final out = <NativeNode>[];
  final seen = <String>{};
  void walk(Map<String, Object?> n, bool insideTappable) {
    if (out.length >= max || _isKeyboard(n)) return;
    final type = n['type'] as String? ?? '';
    final label = (n['label'] as String?) ?? (n['value'] as String?) ?? (n['placeholder'] as String?) ?? '';
    final tappable = _tappable.contains(type) || (type == 'image' && label.isNotEmpty);
    final f = n['frame'];
    if (f is List && f.length == 4 && (tappable || (type == 'text' && !insideTappable)) && (tappable || label.isNotEmpty)) {
      final [x, y, w, h] = [for (final v in f) (v as num).toDouble()];
      final key = '$type|$label|${x.round()},${y.round()}';
      final onScreen = screen == null ||
          (x + w / 2 >= 0 && y + h / 2 >= 0 && x + w / 2 <= screen.w && y + h / 2 <= screen.h);
      if (w > 0 && h > 0 && onScreen && seen.add(key)) {
        out.add((
          cls: type,
          label: label,
          clickable: tappable && n['enabled'] != false,
          x1: x.round(),
          y1: y.round(),
          x2: (x + w).round(),
          y2: (y + h).round(),
        ));
      }
    }
    for (final c in _children(n)) {
      walk(c, insideTappable || tappable);
    }
  }

  for (final r in roots) {
    walk(r, false);
  }
  return out;
}
