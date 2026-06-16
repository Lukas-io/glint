import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../../../perception.dart';
import '../../../semantic.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `get_scene` — the semantic scene for the current screen. Text by
/// default, JSON on request.
class GetSceneTool extends GlintTool {
  const GetSceneTool();

  @override
  Tool get definition => Tool(
        name: 'get_scene',
        description:
            'Read the current screen as a compact role-classified scene. '
            'Each line: `<marker> <role> <glintId> [label]`. '
            'Markers: `*` tappable, `>` typeable, `<>` scrollable, `-` static. '
            'The glintId on each line is the stable address you pass to tap/type/scroll. '
            'When a dialog or modal is open, an `--- dialog ---` section appears first '
            'followed by `--- screen (blocked by modal) ---` for the base screen. '
            'structuredContent includes: hasOverlay (bool), overlayKind (string), '
            'keyboardVisible (bool), route.name, state (loading/loaded/error). '
            'format param: "text" (default) or "json".',
        inputSchema: ObjectSchema(
          properties: {
            'format': Schema.string(
              description: 'Output format. One of: text (default), json',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final format = (args['format'] as String?) ?? 'text';

    // N4: branch on scene mode — native surface uses OS AX tree.
    final isNativeMode = session.sceneMode == SceneMode.native;
    if (isNativeMode) {
      final nativeReader = session.nativeReader;
      if (nativeReader == null) {
        return StructuredResponse.error(
          summary: 'native scene mode is not available on this platform',
          errorKind: GlintErrorKind.unsupportedBackendAction,
        );
      }
      final nativeScene = await nativeReader.readSnapshot();
      final isSentinel = nativeScene.root.glintId == '_native_surface';
      return StructuredResponse(
        summary: isSentinel
            ? '--- native surface active ---\n'
                'A native iOS surface is blocking the Flutter UI. No widget tree available.\n'
                'Options: use `hardware_button home` to return to the app, or wait for the '
                'app to return to the foreground.'
            : '--- native surface ---\n'
                + _renderNativeScene(nativeScene),
        data: {
          'format': format,
          'state': 'native',
          'nativeScene': true,
          'sceneMode': 'native',
        },
      );
    }

    final scene = await session.reader.readSummary();
    try {
      final semantic = session.semanticizer.semanticize(scene);
      // Overlay enrichment first — populates overlayLayers before rendering.
      await session.overlayEnricher.enrich(semantic);
      await session.inputEnricher.enrich(semantic);
      await session.iconEnricher.enrich(semantic);
      await session.navEnricher.enrich(semantic);

      final String rendered;
      switch (format) {
        case 'json':
          rendered = const JsonSceneRenderer().render(semantic);
        case 'text':
          rendered = const PlainTextSceneRenderer().render(semantic);
        default:
          return StructuredResponse.error(
            summary: 'unknown scene format: $format',
            errorKind: GlintErrorKind.invalidArgument,
            nextSteps: const ['use one of: text, json'],
          );
      }

      final state = const StateObserver().observe(semantic);
      final lifecycle = await session.lifecycleState();
      final ui = await session.uiState();
      return StructuredResponse(
        summary: rendered,
        data: {
          'format': format,
          'state': state.name,
          // Only include non-default / non-falsy values to keep structuredContent
          // compact — every key is a token cost.
          if (lifecycle != null && lifecycle != 'resumed') 'lifecycle': lifecycle,
          if (ui.focusedType != null) 'focusedType': ui.focusedType,
          if (ui.keyboardBottomPx > 0) 'keyboardVisible': true,
          if (ui.orientation != null && ui.orientation != 'portrait')
            'orientation': ui.orientation,
          if (ui.brightness != null && ui.brightness != 'light')
            'brightness': ui.brightness,
          if (semantic.routeStack.isNotEmpty)
            'route': semantic.routeStack.first.toJson(),
          if (semantic.overlayLayers.isNotEmpty) ...{
            'hasOverlay': true,
            'overlayKind': semantic.overlayLayers.first.kind,
          },
        },
      );
    } finally {
      await scene.dispose();
    }
  }

  /// Compact text render of a native (AX) scene for agent consumption.
  String _renderNativeScene(Scene scene) {
    final buf = StringBuffer();
    _renderNativeNode(buf, scene.root, depth: 0);
    return buf.toString();
  }

  void _renderNativeNode(StringBuffer buf, SceneNode node, {required int depth}) {
    if (depth > 6) return;
    final label = node.textPreview ?? node.label;
    final marker = (node.isNativeEnabled ?? false) ? '*' : '-';
    final id = node.glintId ?? '';
    if (id.isNotEmpty && !id.startsWith('_native')) {
      buf
        ..write('  ' * depth)
        ..write('$marker native $id $label')
        ..writeln();
    }
    for (final child in node.children) {
      _renderNativeNode(buf, child, depth: depth + 1);
    }
  }
}
