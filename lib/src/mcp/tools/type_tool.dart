import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../armed.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class TypeTool extends GlintTool {
  const TypeTool();

  @override
  Tool get definition => Tool(
        name: 'type',
        description:
            'Type text into the focused input. Pass `focus: <glintId>` to '
            'tap the field first; combine with `awaitReady` to wait for it '
            'to appear before typing.',
        inputSchema: ObjectSchema(
          properties: {
            'text': Schema.string(description: 'Printable-ASCII text to type.'),
            'focus': Schema.string(
              description:
                  'Optional glintId of an input to tap before typing.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Only meaningful with `focus`: block until the focus target is hittable.',
            ),
            'readyTimeoutMs': Schema.int(),
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
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs = (args['readyTimeoutMs'] as int?) ?? 5000;

    final warnings = <String>[];
    ArmingReady? focusArming;

    if (focus != null) {
      final arming = await maybeAwaitReady(
        session: session,
        glintId: focus,
        awaitReady: armed,
        ceilingMs: ceilingMs,
        toolLabel: 'type:focus',
      );
      if (arming is ArmingFailed) return arming.envelope;
      if (arming is ArmingReady) focusArming = arming;

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
      var response = StructuredResponse.fromActionResult(result);
      if (warnings.isNotEmpty || focusArming != null) {
        response = StructuredResponse(
          summary: response.summary,
          warnings: [...warnings, ...response.warnings],
          nextSteps: response.nextSteps,
          data: {
            ...?response.data,
            if (focusArming != null) 'armed': focusArming.toJson(),
          },
          isError: response.isError,
        );
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }
}
