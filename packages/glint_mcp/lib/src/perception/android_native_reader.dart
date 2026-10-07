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
    this.serverCall,
  });

  /// Asks glint's resident server; null when there is none or it failed, and then dumpsys and uiautomator answer instead.
  Future<Map<String, Object?>?> Function(Map<String, Object?> request)? serverCall;

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
    final viaServer = await _serverFocus();
    if (viaServer != null) return viaServer;
    try {
      final r = await run(adbPath, ['-s', serial, 'shell', 'dumpsys', 'window', 'displays']);
      if (r.exitCode != 0) return null;
      return parseFocusedComponent(r.stdout as String);
    } on Object {
      return null;
    }
  }

  /// `package/title` of the focused window from the server, or null when it cannot say.
  Future<String?> _serverFocus() async {
    final r = await serverCall?.call(const {'cmd': 'focus'});
    final pkg = r?['package'];
    if (r?['ok'] != true || pkg is! String) return null;
    return '$pkg/${r!['title'] ?? r['type'] ?? 'window'}';
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
    final r = await serverCall?.call(const {'cmd': 'windows'});
    if (r != null && r['ok'] == true) return sceneFromServerWindows(r, devicePixelRatio());
    try {
      const path = '/data/local/tmp/glint_ui.xml';
      final dump = await run(adbPath, ['-s', serial, 'shell', 'uiautomator', 'dump', path]);
      if (dump.exitCode != 0) {
        final others = await otherDeviceServers(serial, adbPath, run: run);
        lastReadProblem = dump.exitCode == 137
            ? 'uiautomator was killed: another automation tool holds the accessibility connection'
                '${others.isEmpty ? ' (Appium, mobile-mcp, agent-device)' : ': ${others.join(', ')}'}'
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

/// Automation servers other tools left running on the device (`app_process` mains such as mobile-mcp's DeviceServer or scrcpy); they hold the accessibility and screen-capture connections glint needs.
Future<List<String>> otherDeviceServers(String serial, String adbPath,
    {Future<ProcessResult> Function(String, List<String>) run = Process.run}) async {
  try {
    final r = await run(adbPath, ['-s', serial, 'shell', 'ps', '-A', '-o', 'ARGS']);
    return parseDeviceServers(r.stdout as String);
  } on Object {
    return const [];
  }
}

/// Main classes of `app_process` servers in a `ps -o ARGS` listing.
List<String> parseDeviceServers(String ps) => [
      for (final m in RegExp(r'app_process\S*\s+\S+\s+([\w.]+)').allMatches(ps))
        if (m.group(1)!.contains('.')) m.group(1)!,
    ];

/// The `package/activity` in `mCurrentFocus=Window{… u0 package/activity}`, or null.
String? parseFocusedComponent(String dumpsys) {
  final m = RegExp(r'mCurrentFocus=Window\{\S+ \S+ ([^\s}]+)\}').firstMatch(dumpsys);
  final c = m?.group(1);
  return c == null || !c.contains('/') ? null : c;
}

/// One node a native reader found: class, label, whether it is tappable, and its bounds in pixels.
typedef NativeNode = ({String cls, String label, bool clickable, int x1, int y1, int x2, int y2});

/// Flat scene of the labelled or tappable nodes in a `uiautomator dump`, framed in logical points.
Scene sceneFromUiDump(String xml, double dpr) {
  final nodes = <NativeNode>[];
  for (final m in RegExp(r'<node ([^>]*?)/?>').allMatches(xml)) {
    final a = {
      for (final kv in RegExp(r'([\w-]+)="([^"]*)"').allMatches(m.group(1)!))
        kv.group(1)!: _unescape(kv.group(2)!),
    };
    final text = a['text'] ?? '';
    final b = RegExp(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]').firstMatch(a['bounds'] ?? '');
    if (b == null) continue;
    nodes.add((
      cls: (a['class'] ?? 'View').split('.').last,
      label: text.isNotEmpty ? text : (a['content-desc'] ?? ''),
      clickable: a['clickable'] == 'true',
      x1: int.parse(b.group(1)!),
      y1: int.parse(b.group(2)!),
      x2: int.parse(b.group(3)!),
      y2: int.parse(b.group(4)!),
    ));
  }
  return nativeScene(nodes, dpr);
}

/// Flat scene of the focused window in the server's `windows` reply (the top application window when none has focus).
Scene sceneFromServerWindows(Map<String, Object?> reply, double dpr) {
  final windows = [for (final w in (reply['windows'] as List? ?? const [])) (w as Map).cast<String, Object?>()];
  final chosen = windows.where((w) => w['focused'] == true).firstOrNull ??
      windows.where((w) => w['type'] == 'application').firstOrNull;
  final nodes = <NativeNode>[];
  void walk(Map<String, Object?> n) {
    final b = (n['bounds'] as List?)?.cast<num>();
    final text = n['text'] as String? ?? '';
    if (b != null && b.length == 4) {
      nodes.add((
        cls: ((n['class'] as String?) ?? 'View').split('.').last,
        label: text.isNotEmpty ? text : (n['desc'] as String? ?? ''),
        clickable: n['clickable'] == true,
        x1: b[0].toInt(),
        y1: b[1].toInt(),
        x2: b[2].toInt(),
        y2: b[3].toInt(),
      ));
    }
    for (final c in (n['children'] as List? ?? const [])) {
      walk((c as Map).cast<String, Object?>());
    }
  }

  final root = chosen?['root'];
  if (root is Map) walk(root.cast<String, Object?>());
  return nativeScene(nodes, dpr);
}

/// The labelled or tappable [nodes] as a flat native scene in logical points.
Scene nativeScene(Iterable<NativeNode> nodes, double dpr) {
  final root = SceneNode(
    depth: 0,
    indexInParent: -1,
    description: '_NativeRoot',
    type: 'native',
    inspectorId: '',
  )..glintId = '_native_root';
  final used = <String, int>{};
  final kids = <SceneNode>[];
  for (final n in nodes) {
    if (n.label.isEmpty && !n.clickable) continue;
    if (n.x2 <= n.x1 || n.y2 <= n.y1) continue;
    final base = _slug(n.label.isNotEmpty ? n.label : n.cls);
    final count = used.update(base, (v) => v + 1, ifAbsent: () => 1);
    kids.add(SceneNode(
      depth: 1,
      indexInParent: kids.length,
      description: n.cls,
      type: 'native',
      inspectorId: '',
      widgetRuntimeType: n.cls,
      textPreview: n.label.isEmpty ? null : n.label,
      createdByLocalProject: true,
    )
      ..glintId = count == 1 ? 'native_$base' : 'native_${base}_$count'
      ..isNativeEnabled = n.clickable
      ..axFrame = (x: n.x1 / dpr, y: n.y1 / dpr, w: (n.x2 - n.x1) / dpr, h: (n.y2 - n.y1) / dpr));
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
