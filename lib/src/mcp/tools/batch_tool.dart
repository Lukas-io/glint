import 'package:dart_mcp/server.dart';

import '../../../semantic.dart';
import '../batch_runner.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `batch` — run an ordered list of gesture steps server-side in one call.
/// Each step settles like a normal call; the batch stops at the first error
/// or (by default) the first step that changed nothing, and returns one
/// final scene. Cuts a known N-step flow from N round trips to one.
class BatchTool extends GlintTool {
  const BatchTool();

  static const int _maxSteps = 20;

  @override
  Tool get definition => Tool(
        name: 'batch',
        description:
            'Run several steps in ONE call: steps:[{tool, args}] over '
            '${kBatchStepTools.keys.join(", ")}. Each step settles like a '
            'normal call and reports changed/changeCategory; the batch stops '
            'at the first error or, with stopOnNoChange (default true), the '
            'first step that changed nothing, then returns per-step results '
            'and the final scene. Targeted steps default to awaitReady:true so '
            'a step may name an id the previous step reveals. Use for a known '
            'sequence (fill a form, walk a wizard); use single calls when the '
            'next move depends on what you see.',
        inputSchema: ObjectSchema(
          properties: {
            'steps': batchStepsSchema(
              _maxSteps,
              description:
                  'Ordered steps, each {tool: "<name>", args: {…}} with the '
                  'same args the tool takes on its own. Max $_maxSteps.',
            ),
            'stopOnNoChange': Schema.bool(
              description:
                  'Stop when a step reports changed:false. Default true.',
            ),
            'returnScene': Schema.bool(
              description: 'Append the final scene text. Default true.',
            ),
          },
          required: ['steps'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final stopOnNoChange = (args['stopOnNoChange'] as bool?) ?? true;
    final returnScene = (args['returnScene'] as bool?) ?? true;

    final parsed = parseBatchSteps(args['steps'], maxSteps: _maxSteps);
    if (parsed.error != null) return parsed.error!;
    final steps = parsed.steps!;

    final run =
        await runBatchSteps(session, steps, stopOnNoChange: stopOnNoChange);

    final results = [for (final o in run.outcomes) o.toJson()];
    final lines = [for (final o in run.outcomes) o.line()];

    String? scene;
    if (returnScene && !session.isDeviceMode) {
      try {
        scene = await session.withScene(
            (s) async => const PlainTextSceneRenderer().render(s));
      } on Object {
        scene = null;
      }
    }

    final header = run.stoppedAt == null
        ? 'ran ${steps.length}/${steps.length} step(s)'
        : run.reason == 'error'
            ? 'stopped at step ${run.stoppedAt} of ${steps.length} (error)'
            : 'stopped at step ${run.stoppedAt} of ${steps.length}: nothing changed';
    return StructuredResponse(
      summary: [
        header,
        ...lines,
        if (scene != null) '',
        if (scene != null) '--- scene after batch ---',
        if (scene != null) scene.trimRight(),
      ].join('\n'),
      isError: run.reason == 'error',
      nextSteps: [
        if (run.reason == 'error')
          'read the failing step\'s detail above, fix its args, and resume from step ${run.stoppedAt}',
        if (run.reason == 'noChange')
          'step ${run.stoppedAt} did nothing — re-read the scene (or the scene above) before continuing',
      ],
      data: {
        'steps': results,
        'completedSteps': run.completed,
        'totalSteps': steps.length,
        if (run.stoppedAt != null) 'stoppedAt': run.stoppedAt,
        if (run.reason != null) 'reason': run.reason,
        if (run.reason == 'error') 'errorKind': results.last['errorKind'],
      },
    );
  }
}
