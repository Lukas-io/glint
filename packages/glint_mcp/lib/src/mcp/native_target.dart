import '../../interaction.dart';
import '../../perception.dart';
import 'envelope.dart';
import 'session.dart';

/// A native node a tool named by `glintId` or `text`, at its center in logical points.
typedef NativeHit = ({double x, double y, String label});

/// Resolves [glintId] / [text] against the native surface over the app (in device mode, the runner's read of the screen, in pixels); null when the app's own screen is in front, so the Flutter path runs.
Future<({NativeHit? hit, StructuredResponse? error})?> resolveNativeTarget(GlintSession session,
    {String? glintId, String? text}) async {
  final reader = session.nativeReader;
  if (reader == null || (glintId == null && text == null)) return null;
  if (reader is AndroidNativeReader) await session.active?.refreshSceneMode();
  if (session.sceneMode != SceneMode.native) return null;
  final scene =
      session.isDeviceMode && reader is RunnerNativeReader ? await reader.readFresh() : await reader.readSnapshot();
  final what = session.isDeviceMode ? 'screen' : 'native surface';
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
  if (found == null && scene.root.glintId == '_native_surface') {
    return (
      hit: null,
      error: StructuredResponse.error(
        summary: 'glint cannot read the native surface over the app, so it cannot find '
            '${glintId != null ? 'node $glintId' : '"$text"'} on it',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'the simulator accessibility read failed (its Simulator window is closed, or the read was refused)',
        nextSteps: const [
          'take a `device op:screenshot` and tap the button by x,y',
          'or attach again so the XCTest runner starts (config iosNativeRunner), which reads system surfaces without a window',
        ],
      ),
    );
  }
  if (found == null) {
    final seen = [for (final n in nodes.take(12)) '"${n.textPreview ?? n.glintId}"'];
    return (
      hit: null,
      error: StructuredResponse.error(
        summary:
            'no ${glintId != null ? 'node $glintId' : '"$text"'} on the ${session.isDeviceMode ? 'screen' : 'native surface over the app'}',
        errorKind: GlintErrorKind.targetNotFound,
        detail: seen.isEmpty ? 'the $what shows no readable text' : 'it shows ${seen.join(', ')}',
        nextSteps: ['call get_scene to read the $what, then tap one of its items by text or glintId'],
      ),
    );
  }
  final f = found.axFrame!;
  return (hit: (x: f.x + f.w / 2, y: f.y + f.h / 2, label: found.textPreview ?? found.glintId!), error: null);
}

/// Device mode with the runner: [response] plus what is in front once the screen has stopped changing, so the next step needs no extra look; unchanged elsewhere and on errors.
Future<StructuredResponse> withNativeAftermath(GlintSession session, StructuredResponse response) async {
  final reader = session.nativeReader;
  if (response.isError || !session.isDeviceMode || reader is! RunnerNativeReader) return response;
  final front = await _settledSurface(reader);
  final problem = reader.lastReadProblem;
  return response.copyWith(
    summary: '${response.summary}\nnow in front: ${front ?? 'nothing the runner can read'}',
    warnings: [...response.warnings, if (problem != null) problem],
    nextSteps: [...response.nextSteps, 'get_scene lists what is on screen to tap by text or glintId'],
  ).mergeData({'nativeSurface': front});
}

Future<String?> _settledSurface(RunnerNativeReader reader) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  var front = await reader.foreignSurface();
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final again = await reader.foreignSurface();
    if (again == front) break;
    front = again;
  }
  return front;
}

Iterable<SceneNode> _walk(SceneNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* _walk(c);
  }
}
