import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
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
            'Every interactive node is marked: `*` tappable, `>` typeable, `<>` scrollable. '
            'The glintId on each line is the address you pass to tap / swipe / type.',
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

    final scene = await session.reader.readSummary();
    try {
      final semantic = session.semanticizer.semanticize(scene);

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

      final counts = _coverage(semantic);
      return StructuredResponse(
        summary: rendered,
        data: {
          'format': format,
          'coverage': counts,
        },
      );
    } finally {
      await scene.dispose();
    }
  }

  Map<String, int> _coverage(SemanticScene scene) {
    final counts = <String, int>{};
    for (final n in scene.root.walk()) {
      counts.update(n.role.name, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }
}
