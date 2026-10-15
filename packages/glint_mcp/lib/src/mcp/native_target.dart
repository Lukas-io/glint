import '../../interaction.dart';
import '../../perception.dart';
import 'envelope.dart';
import 'session.dart';

/// A native node a tool named by `glintId` or `text`, at its center in logical points.
typedef NativeHit = ({double x, double y, String label});

/// Resolves [glintId] / [text] against the native surface over the app; null when the app's own screen is in front, so the Flutter path runs.
Future<({NativeHit? hit, StructuredResponse? error})?> resolveNativeTarget(
    GlintSession session, {String? glintId, String? text}) async {
  final reader = session.nativeReader;
  if (session.isDeviceMode || reader == null || (glintId == null && text == null)) return null;
  if (reader is AndroidNativeReader) await session.active?.refreshSceneMode();
  if (session.sceneMode != SceneMode.native) return null;
  final scene = await reader.readSnapshot();
  final nodes = [
    for (final n in _walk(scene.root))
      if (n.axFrame != null && n.glintId != null && !n.glintId!.startsWith('_native')) n,
  ];
  SceneNode? found;
  if (glintId != null) {
    found = nodes.where((n) => n.glintId == glintId).firstOrNull;
  } else {
    final want = text!.trim().toLowerCase();
    bool exact(SceneNode n) => n.textPreview?.trim().toLowerCase() == want;
    bool part(SceneNode n) => n.textPreview?.toLowerCase().contains(want) ?? false;
    bool enabled(SceneNode n) => n.isNativeEnabled == true;
    found = [
      ...nodes.where((n) => exact(n) && enabled(n)),
      ...nodes.where((n) => exact(n) && !enabled(n)),
      ...nodes.where((n) => !exact(n) && part(n) && enabled(n)),
      ...nodes.where((n) => !exact(n) && part(n) && !enabled(n)),
    ].firstOrNull;
  }
  if (found == null) {
    final seen = [for (final n in nodes.take(12)) '"${n.textPreview ?? n.glintId}"'];
    return (
      hit: null,
      error: StructuredResponse.error(
        summary: 'no ${glintId != null ? 'node $glintId' : '"$text"'} on the native surface over the app',
        errorKind: GlintErrorKind.targetNotFound,
        detail: seen.isEmpty ? 'the native surface shows no readable text' : 'it shows ${seen.join(', ')}',
        nextSteps: const ['call get_scene to read the surface, then tap one of its items by text or glintId'],
      ),
    );
  }
  final f = found.axFrame!;
  return (hit: (x: f.x + f.w / 2, y: f.y + f.h / 2, label: found.textPreview ?? found.glintId!), error: null);
}

Iterable<SceneNode> _walk(SceneNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* _walk(c);
  }
}
