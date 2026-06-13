import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class TypeTool extends GlintTool {
  const TypeTool();

  @override
  Tool get definition => Tool(
        name: 'type',
        description:
            'Type text into the currently focused input. Pass `focus: <glintId>` to tap the '
            'field first — recommended unless you know the input is already focused.',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(description: 'Printable-ASCII text to type.'),
            'focus': Schema.string(
              description:
                  'Optional glintId of an input to tap before typing.',
            ),
          },
          required: ['text'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final text = args['text']! as String;
    final focus = args['focus'] as String?;

    final warnings = <String>[];

    if (focus != null) {
      final scene = await session.reader.readSummary();
      try {
        final focusResult = await session.interactor.run(
          scene,
          Tap(SymbolicTarget(focus)),
        );
        if (!focusResult.ok) {
          return StructuredResponse.error(
            summary: 'failed to focus $focus before typing',
            errorKind: focusResult.errorKind ?? GlintErrorKind.internal,
            detail: focusResult.error,
            nextSteps: focusResult.nextSteps,
          );
        }
        warnings.addAll(focusResult.warnings);
      } finally {
        await scene.dispose();
      }
    }

    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(scene, TypeText(text));
      final response = StructuredResponse.fromActionResult(result);
      if (warnings.isEmpty) return response;
      return StructuredResponse(
        summary: response.summary,
        warnings: [...warnings, ...response.warnings],
        nextSteps: response.nextSteps,
        data: response.data,
        isError: response.isError,
      );
    } finally {
      await scene.dispose();
    }
  }
}
