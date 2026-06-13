import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

class TapTool extends GlintTool {
  const TapTool();

  @override
  Tool get definition => Tool(
        name: 'tap',
        description:
            'Tap a node by its glintId. With `awaitReady: true`, blocks '
            'until the target exists AND is hittable, then fires '
            '(§7.2 armed intent). Catch is structured: `targetNeverReady` '
            'if it never becomes hittable within `readyTimeoutMs`.',
        inputSchema: ObjectSchema(
          properties: {
            'glintId': Schema.string(
              description:
                  'Stable id from `get_scene`, e.g. floating_action_button',
            ),
            'refuseNotHittable': Schema.bool(
              description:
                  'When true, a non-hittable target produces an error (errorKind=notHittable) instead of a warning. Default false.',
            ),
            'awaitReady': Schema.bool(
              description:
                  'Arm the tap: block until the target is in the scene AND passes a hit test, then fire. Default false.',
            ),
            'readyTimeoutMs': Schema.int(
              description: 'Ceiling for `awaitReady`. Default 5000.',
            ),
          },
          required: ['glintId'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final glintId = args['glintId']! as String;
    final refuse = (args['refuseNotHittable'] as bool?) ?? false;
    final armed = (args['awaitReady'] as bool?) ?? false;
    final ceilingMs = (args['readyTimeoutMs'] as int?) ?? 5000;

    Map<String, Object?>? armedData;
    if (armed) {
      final result = await session.readinessGate
          .awaitReady(glintId: glintId, ceilingMs: ceilingMs);
      switch (result) {
        case ReadyResult():
          armedData = {
            'attempts': result.attempts,
            'elapsedMs': result.elapsedMs,
          };
        case NotFoundResult():
          return StructuredResponse.error(
            summary: 'armed tap on $glintId: target never appeared '
                '(${result.attempts} polls, ${result.elapsedMs}ms)',
            errorKind: GlintErrorKind.unresolvedTarget,
            detail: 'no scene poll within $ceilingMs ms ever saw glintId="$glintId"',
            nextSteps: const [
              'verify the glintId via `get_scene`',
              'raise `readyTimeoutMs` if the target arrives slowly',
            ],
          );
        case NeverReadyResult():
          return StructuredResponse.error(
            summary: 'armed tap on $glintId: present but never hittable '
                '(${result.attempts} polls, ${result.elapsedMs}ms)',
            errorKind: GlintErrorKind.targetNeverReady,
            detail: result.detail,
            nextSteps: const [
              'check if a modal, absorber, or overlay covers the target',
              'raise `readyTimeoutMs` if the target settles slowly',
            ],
          );
      }
    }

    final scene = await session.reader.readSummary();
    try {
      final interactor = session.interactor..refuseNotHittable = refuse;
      final result = await interactor.run(scene, Tap(SymbolicTarget(glintId)));
      final response = StructuredResponse.fromActionResult(result);
      if (armedData == null) return response;
      return StructuredResponse(
        summary: 'armed tap on $glintId fired after '
            '${armedData['attempts']} polls / ${armedData['elapsedMs']}ms — '
            '${response.summary}',
        warnings: response.warnings,
        nextSteps: response.nextSteps,
        data: {...?response.data, 'armed': armedData},
        isError: response.isError,
      );
    } finally {
      await scene.dispose();
    }
  }
}
