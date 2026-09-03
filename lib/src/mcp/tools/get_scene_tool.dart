import 'dart:convert';

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
            'keyboardVisible (bool), route.name, state '
            '(loaded/loading/error, or device/native when no Flutter tree). '
            'format param: "text" (default) or "json"; json also carries an '
            'overlayLayers array when a dialog is open. '
            'glintId: render only that node\'s subtree (drill-down); depth '
            'caps how many levels below it are shown.',
        inputSchema: ObjectSchema(
          properties: {
            'format': Schema.string(
              description: 'Output format. One of: text (default), json',
            ),
            'glintId': Schema.string(
              description:
                  'Only this node and its descendants. Use to drill into one '
                  'container or list instead of re-reading the whole screen.',
            ),
            'depth': Schema.int(
              description:
                  'With glintId: levels below it to include (0 = the node '
                  'only). Default: all, up to the renderer\'s cap.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final format = (args['format'] as String?) ?? 'text';
    final glintId = args['glintId'] as String?;
    final depth = args['depth'] as int?;

    // Validate format up front — before the scene read + VM-eval enrichers,
    // so a bad arg fails cheaply instead of after the round-trips.
    if (format != 'text' && format != 'json') {
      return StructuredResponse.error(
        summary: 'unknown scene format: $format',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: text, json'],
      );
    }

    // Device mode: no Flutter widget tree on this attachment.
    if (session.isDeviceMode) {
      return StructuredResponse(
        summary: 'device mode: no Flutter widget tree.\n'
            'Use `device op:screenshot` to see the screen, then tap / swipe '
            'with x,y in screenshot pixels.',
        data: {'mode': 'device', 'state': 'device'},
      );
    }

    if (session.sceneMode == SceneMode.native) {
      await session.active?.refreshSceneMode();
    }
    if (session.sceneMode == SceneMode.native) {
      return _handleNativeMode(session, format);
    }

    try {
      return await _readFlutterScene(session, format,
          glintId: glintId, depth: depth);
    } on InspectorReadError catch (e) {
      // A null widget tree usually means no frame to inspect — the app is
      // backgrounded or paused behind a native surface (permission dialog,
      // another app). Translate the raw stack trace into an actionable state.
      final lifecycle = await _safeLifecycle(session);
      if (lifecycle != null && lifecycle != 'resumed') {
        return StructuredResponse.error(
          summary: 'the app is "$lifecycle", not resumed — no Flutter frame to '
              'read. A native dialog or another app is likely in front.',
          errorKind: GlintErrorKind.appNotResumed,
          detail: e.toString(),
          nextSteps: const [
            'take a `device op:screenshot` to see what is on top',
            'dismiss the native surface (e.g. tap its button via raw x,y), '
                'then retry get_scene',
            'or `hardware_button home` then reopen the app',
          ],
        );
      }
      rethrow;
    }
  }

  Future<StructuredResponse> _readFlutterScene(
    GlintSession session,
    String format, {
    String? glintId,
    int? depth,
  }) async {
    return session.withScene((semantic) async {
      SemanticNode? subtree;
      if (glintId != null) {
        subtree = semantic.findByGlintId(glintId) ??
            semantic.overlayLayers
                .expand((l) => l.nodes)
                .expand((n) => n.walk())
                .cast<SemanticNode?>()
                .firstWhere((n) => n!.glintId == glintId, orElse: () => null);
        if (subtree == null) {
          final ids = [
            for (final n in semantic.root.walk())
              if (n.glintId != null) n.glintId!,
          ];
          final hint = didYouMean(suggestIds(ids, glintId));
          return StructuredResponse.error(
            summary: 'no node with glintId "$glintId" on this screen',
            errorKind: GlintErrorKind.unresolvedTarget,
            nextSteps: [
              if (hint != null) hint,
              'call get_scene without glintId to read the current ids',
            ],
          );
        }
      }

      final String rendered;
      if (subtree != null) {
        rendered = format == 'json'
            ? const JsonEncoder.withIndent('  ')
                .convert(_pruneDepth(subtree.toJson(), depth))
            : const PlainTextSceneRenderer()
                .renderSubtree(subtree, maxDepth: depth);
      } else {
        rendered = format == 'json'
            ? const JsonSceneRenderer().render(semantic)
            : const PlainTextSceneRenderer().render(semantic);
      }

      final state = const StateObserver().observe(semantic);
      final lifecycle = await session.lifecycleState();
      final ui = await session.uiState();
      final route =
          semantic.routeStack.isEmpty ? null : semantic.routeStack.first;
      final overlay = semantic.overlayLayers.isEmpty
          ? null
          : semantic.overlayLayers.first.kind;
      final trailer = [
        'state: ${state.name}',
        if (lifecycle != null && lifecycle != 'resumed') 'lifecycle: $lifecycle',
        if (route != null) 'route: ${route.name}',
        if (overlay != null) 'overlay: $overlay',
        if (ui.focusedType != null) 'focused: ${ui.focusedType}',
        if (ui.keyboardBottomPx > 0) 'keyboard: visible',
        if (ui.orientation != null && ui.orientation != 'portrait')
          'orientation: ${ui.orientation}',
        if (ui.brightness != null && ui.brightness != 'light')
          'brightness: ${ui.brightness}',
        if (subtree != null) 'subtree: $glintId',
      ].join(' · ');

      if (format == 'json') {
        return StructuredResponse(
          summary: rendered,
          data: {
            'format': format,
            'state': state.name,
            if (lifecycle != null && lifecycle != 'resumed')
              'lifecycle': lifecycle,
            if (ui.focusedType != null) 'focusedType': ui.focusedType,
            if (ui.keyboardBottomPx > 0) 'keyboardVisible': true,
            if (ui.orientation != null && ui.orientation != 'portrait')
              'orientation': ui.orientation,
            if (ui.brightness != null && ui.brightness != 'light')
              'brightness': ui.brightness,
            if (route != null) 'route': route.toJson(),
            if (overlay != null) ...{'hasOverlay': true, 'overlayKind': overlay},
            if (subtree != null) 'subtree': glintId,
          },
        );
      }
      return StructuredResponse(
        summary: '${rendered.trimRight()}\n$trailer',
        textOnly: true,
      );
    });
  }

  /// Drops `children` below [depth] levels (null = unlimited).
  static Map<String, Object?> _pruneDepth(Map<String, Object?> node, int? depth) {
    if (depth == null) return node;
    final kids = node['children'];
    if (kids is! List) return node;
    if (depth <= 0) {
      return {for (final e in node.entries) if (e.key != 'children') e.key: e.value,
        'childCount': kids.length};
    }
    return {
      ...node,
      'children': [
        for (final k in kids)
          if (k is Map<String, Object?>) _pruneDepth(k, depth - 1) else k,
      ],
    };
  }

  Future<String?> _safeLifecycle(GlintSession session) async {
    try {
      return await session.lifecycleState();
    } on Object {
      return null;
    }
  }

  Future<StructuredResponse> _handleNativeMode(
      GlintSession session, String format) async {
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
          : '--- native surface ---\n${NativeSceneReader.renderAsText(nativeScene)}',
      data: {
        'format': format,
        'state': 'native',
        'nativeScene': true,
        'sceneMode': 'native',
      },
    );
  }
}
