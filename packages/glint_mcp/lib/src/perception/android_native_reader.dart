import 'dart:io';

import 'native_scene_reader.dart';
import 'scene_node.dart';
import 'scene_reader.dart';

/// Android native surfaces: the window manager says whose window has focus, and `uiautomator dump` reads it.
class AndroidNativeReader extends NativeReader {
  AndroidNativeReader({
    required this.serial,
    required this.adbPath,
    required this.devicePixelRatio,
    this.run = Process.run,
  });

  final String serial;
  final String adbPath;
  final double Function() devicePixelRatio;
  final Future<ProcessResult> Function(String, List<String>) run;

  /// Package that owns the app's window, learned while the app is in front.
  String? appPackage;

  /// Why the last [readSnapshot] could not read the surface, for the reply.
  String? lastReadProblem;

  /// `package/activity` of the focused window, or null when adb cannot say.
  Future<String?> focusedComponent() async {
    try {
      final r = await run(adbPath, ['-s', serial, 'shell', 'dumpsys', 'window', 'displays']);
      if (r.exitCode != 0) return null;
      return parseFocusedComponent(r.stdout as String);
    } on Object {
      return null;
    }
  }

  /// Records the focused package as the app's own; call only while Flutter reports `resumed`, when its activity has focus.
  Future<void> learnAppPackage() async {
    final c = await focusedComponent();
    if (c != null) appPackage = c.split('/').first;
  }

  @override
  Future<String?> foreignSurface() async {
    final app = appPackage;
    if (app == null) return null;
    final c = await focusedComponent();
    if (c == null || c.startsWith('$app/')) return null;
    return c;
  }

  @override
  Future<Scene> readSnapshot() async {
    lastReadProblem = null;
    try {
      const path = '/data/local/tmp/glint_ui.xml';
      final dump = await run(adbPath, ['-s', serial, 'shell', 'uiautomator', 'dump', path]);
      if (dump.exitCode != 0) {
        lastReadProblem = dump.exitCode == 137
            ? 'uiautomator was killed: another automation tool on the device (Appium, mobile-mcp, agent-device) likely holds the accessibility connection'
            : 'uiautomator dump failed (exit ${dump.exitCode})';
        return _sentinel();
      }
      final xml = await run(adbPath, ['-s', serial, 'exec-out', 'cat', path]);
      return sceneFromUiDump(xml.stdout as String, devicePixelRatio());
    } on Object catch (e) {
      lastReadProblem = 'uiautomator dump failed: $e';
      return _sentinel();
    }
  }

  static Scene _sentinel() {
    final root = SceneNode(
      depth: 0,
      indexInParent: -1,
      description: '_NativeSurface',
      type: 'native',
      inspectorId: '',
    )..glintId = '_native_surface';
    return Scene.native(root: root);
  }
}

/// The `package/activity` in `mCurrentFocus=Window{… u0 package/activity}`, or null.
String? parseFocusedComponent(String dumpsys) {
  final m = RegExp(r'mCurrentFocus=Window\{\S+ \S+ ([^\s}]+)\}').firstMatch(dumpsys);
  final c = m?.group(1);
  return c == null || !c.contains('/') ? null : c;
}

/// Flat scene of the labelled or tappable nodes in a `uiautomator dump`, framed in logical points.
Scene sceneFromUiDump(String xml, double dpr) {
  final root = SceneNode(
    depth: 0,
    indexInParent: -1,
    description: '_NativeRoot',
    type: 'native',
    inspectorId: '',
  )..glintId = '_native_root';
  final used = <String, int>{};
  final kids = <SceneNode>[];
  for (final m in RegExp(r'<node ([^>]*?)/?>').allMatches(xml)) {
    final a = {
      for (final kv in RegExp(r'([\w-]+)="([^"]*)"').allMatches(m.group(1)!))
        kv.group(1)!: _unescape(kv.group(2)!),
    };
    final text = a['text'] ?? '';
    final desc = a['content-desc'] ?? '';
    final clickable = a['clickable'] == 'true';
    final label = text.isNotEmpty ? text : desc;
    if (label.isEmpty && !clickable) continue;
    final b = RegExp(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]').firstMatch(a['bounds'] ?? '');
    if (b == null) continue;
    final x1 = int.parse(b.group(1)!), y1 = int.parse(b.group(2)!);
    final x2 = int.parse(b.group(3)!), y2 = int.parse(b.group(4)!);
    if (x2 <= x1 || y2 <= y1) continue;
    final cls = (a['class'] ?? 'View').split('.').last;
    final base = _slug(label.isNotEmpty ? label : cls);
    final n = used.update(base, (v) => v + 1, ifAbsent: () => 1);
    kids.add(SceneNode(
      depth: 1,
      indexInParent: kids.length,
      description: cls,
      type: 'native',
      inspectorId: '',
      widgetRuntimeType: cls,
      textPreview: label.isEmpty ? null : label,
      createdByLocalProject: true,
    )
      ..glintId = n == 1 ? 'native_$base' : 'native_${base}_$n'
      ..isNativeEnabled = clickable
      ..axFrame = (x: x1 / dpr, y: y1 / dpr, w: (x2 - x1) / dpr, h: (y2 - y1) / dpr));
  }
  root.children = kids;
  return Scene.native(root: root);
}

String _slug(String s) {
  final slug = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  final cut = slug.length > 32 ? slug.substring(0, 32) : slug;
  return cut.isEmpty ? 'node' : cut;
}

String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
