import 'native_scene_reader.dart';
import 'scene_node.dart';
import 'scene_reader.dart';

/// One line of recognised text with its box in screenshot pixels.
typedef RecognisedLine = ({String text, double x, double y, double w, double h});

/// Reads a native surface over the app from a screenshot with text recognition, each line becoming a node at its place; for devices whose accessibility tree glint cannot reach.
class OcrNativeReader extends NativeReader {
  OcrNativeReader({required this.capture, required this.recognize, required this.devicePixelRatio});

  /// Captures the screen and returns the PNG path, or null when it fails.
  final Future<String?> Function() capture;
  final Future<List<RecognisedLine>> Function(String path) recognize;
  final double Function() devicePixelRatio;

  /// Why the last read came back empty, for the reply.
  String? lastReadProblem;

  @override
  Future<Scene> readSnapshot() async {
    lastReadProblem = null;
    final path = await capture();
    if (path == null) {
      lastReadProblem = 'the screenshot for reading the native surface failed';
      return _sentinel();
    }
    return readFrom(path);
  }

  /// Reads the surface from a screenshot already taken at [path].
  Future<Scene> readFrom(String path) async {
    lastReadProblem = null;
    final List<RecognisedLine> lines;
    try {
      lines = await recognize(path);
    } on Object catch (e) {
      lastReadProblem = 'text recognition failed: $e';
      return _sentinel();
    }
    final dpr = devicePixelRatio();
    final root = SceneNode(depth: 0, indexInParent: -1, description: '_NativeRoot', type: 'native', inspectorId: '')
      ..glintId = '_native_root';
    final used = <String, int>{};
    root.children = [
      for (final l in lines)
        if (l.text.trim().isNotEmpty && l.w > 0 && l.h > 0)
          SceneNode(
            depth: 1,
            indexInParent: 0,
            description: 'text',
            type: 'native',
            inspectorId: '',
            widgetRuntimeType: 'text',
            textPreview: l.text.trim(),
            createdByLocalProject: true,
          )
            ..glintId = _id(l.text, used)
            ..isNativeEnabled = true
            ..axFrame = (x: l.x / dpr, y: l.y / dpr, w: l.w / dpr, h: l.h / dpr),
    ];
    return Scene.native(root: root);
  }

  String _id(String text, Map<String, int> used) {
    var base = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    if (base.length > 32) base = base.substring(0, 32);
    if (base.isEmpty) base = 'text';
    final n = used.update(base, (v) => v + 1, ifAbsent: () => 1);
    return n == 1 ? 'native_$base' : 'native_${base}_$n';
  }

  Scene _sentinel() {
    final root = SceneNode(depth: 0, indexInParent: -1, description: '_NativeSurface', type: 'native', inspectorId: '')
      ..glintId = '_native_surface';
    return Scene.native(root: root);
  }
}
