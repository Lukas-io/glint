import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../semantic.dart';
import '../batch_runner.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// `batch` — run an ordered list of gesture steps server-side in one call.
/// Each step settles like a normal call; the batch stops at the first error
/// or (by default) the first step that changed nothing, and returns one
/// final scene. Cuts a known N-step flow from N round trips to one.
class BatchTool extends GlintTool {
  const BatchTool();

  static const int _maxSteps = 20;
  static const int _defaultBudgetMs = 120000;
  static const int _minBudgetMs = 5000;
  static const int _maxBudgetMs = 300000;
  static const Duration _replyMargin = Duration(seconds: 20);

  @override
  bool changesDevice(Map<String, Object?> args) => stepsChangeDevice(args['steps']);

  /// Each step is checked against the app it targets, so the active app's flag alone decides nothing here.
  @override
  StructuredResponse? observeRefusal(AppSession? app, Map<String, Object?> args) => null;

  @override
  Tool get definition => Tool(
        name: 'batch',
        description:
            'Run several steps in one call: steps:[{tool,args}] over tap, type, key, scroll, scroll_to_find, swipe, long_press, drag, hardware_button, wait_for_settle, wait_for. Step args may name app:"<name>" to run on another attached app, so one batch can drive several devices (A taps call, B wait_for "Incoming call", B taps Answer). Each step settles and reports changed; the batch stops at the first error, or (stopOnNoChange, default true) at the first step that changed nothing. A step whose args carry expectChange:false (a toggle the app does not visibly react to) never stops the batch on changed:false. Targeted steps default to awaitReady:true. budgetMs (default 120000, max 300000) bounds all steps: when it runs out the batch stops before the next step (errorKind budgetExceeded) and says which steps ran. For known sequences (a form, a wizard); use single calls when the next move depends on what you see.',
        inputSchema: ObjectSchema(
          properties: {
            'steps': batchStepsSchema(
              _maxSteps,
              description: 'Ordered steps, each {tool: "<name>", args: {…}} with the '
                  'same args the tool takes on its own, plus app:"<name>" to run that step on another attached app, and expectChange:false to let it change nothing without stopping the batch. Max $_maxSteps.',
            ),
            'stopOnNoChange': Schema.bool(
              description:
                  'Stop when a step reports changed:false, unless that step has expectChange:false. Default true.',
            ),
            'returnScene': Schema.bool(
              description: 'Append the final scene text. Default true.',
            ),
            'budgetMs': Schema.int(
              description:
                  'Total time for all steps, $_minBudgetMs-$_maxBudgetMs. Default $_defaultBudgetMs. When it runs out the batch stops before the next step and says which steps ran.',
            ),
          },
          required: ['steps'],
        ),
      );

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) =>
      Duration(milliseconds: _budget(args).ms) + _replyMargin;

  static ({int ms, int? asked}) _budget(Map<String, Object?> args) {
    final int? asked;
    try {
      asked = argInt(args, 'budgetMs');
    } on ArgTypeError {
      return (ms: _defaultBudgetMs, asked: null);
    }
    if (asked == null) return (ms: _defaultBudgetMs, asked: null);
    final ms = asked.clamp(_minBudgetMs, _maxBudgetMs);
    return (ms: ms, asked: ms == asked ? null : asked);
  }

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final stopOnNoChange = argBool(args, 'stopOnNoChange') ?? true;
    final returnScene = argBool(args, 'returnScene') ?? true;

    final parsed = parseBatchSteps(args['steps'], maxSteps: _maxSteps);
    if (parsed.error != null) return parsed.error!;
    final steps = parsed.steps!;
    if (observeRefusalForSteps(session, steps) case final refused?) return refused;

    final budget = _budget(args);
    final budgetMs = budget.ms;
    final clock = Stopwatch()..start();
    final run = await runBatchSteps(session, steps,
        stopOnNoChange: stopOnNoChange, budget: Duration(milliseconds: budgetMs), meta: request.meta);
    final overBudget = run.reason == 'budget';

    final results = [for (final o in run.outcomes) o.toJson()];
    final lines = [for (final o in run.outcomes) o.line()];

    String? scene;
    if (returnScene && !session.isDeviceMode) {
      try {
        scene = await session.withScene((s) async => const PlainTextSceneRenderer().render(s));
      } on Object {
        scene = null;
      }
    }

    final unknownReason = run.outcomes.where((o) => o.changeUnknown).map((o) => o.unknownReason).firstOrNull;

    final interrupted = overBudget && run.outcomes.last.interrupted;
    final notRun =
        overBudget ? [for (var k = run.stoppedAt! + (interrupted ? 1 : 0); k <= steps.length; k++) k] : <int>[];
    final header = run.stoppedAt == null
        ? 'ran ${steps.length}/${steps.length} step(s)'
        : interrupted
            ? 'stopped in step ${run.stoppedAt} of ${steps.length}: the ${budgetMs ~/ 1000} s budget ran out while it was running (interrupted, outcome unknown)'
            : overBudget
                ? 'stopped before step ${run.stoppedAt} of ${steps.length}: the ${budgetMs ~/ 1000} s budget ran out after ${run.completed} step(s)'
                : run.reason == 'error'
                    ? 'stopped at step ${run.stoppedAt} of ${steps.length} (error)'
                    : 'stopped at step ${run.stoppedAt} of ${steps.length}: nothing changed';
    return StructuredResponse(
      warnings: [
        if (budget.asked != null)
          'budgetMs ${budget.asked} is ${budget.asked! < _minBudgetMs ? 'below the minimum of $_minBudgetMs' : 'above the cap of $_maxBudgetMs'}; used $budgetMs',
      ],
      summary: [
        header,
        ...lines,
        if (scene != null) '',
        if (scene != null) '--- scene after batch ---',
        if (scene != null) scene.trimRight(),
      ].join('\n'),
      isError: run.reason == 'error' || overBudget,
      nextSteps: [
        if (overBudget) ...[
          if (run.completed > 0) 'steps 1-${run.completed} ran and are done; do not repeat them',
          if (interrupted)
            'step ${run.stoppedAt} was interrupted and its outcome is unknown: get_scene first, then repeat it only if it did not happen'
          else
            'continue with a new batch starting at step ${run.stoppedAt}',
          if (interrupted && notRun.isNotEmpty) 'steps ${notRun.first}-${notRun.last} did not run',
          'give the next batch budgetMs up to $_maxBudgetMs, or fewer steps',
          'get_scene shows where the app stands now',
        ],
        if (run.reason == 'error')
          'read the failing step\'s detail above, fix its args, and resume from step ${run.stoppedAt}',
        if (run.reason == 'noChange')
          'step ${run.stoppedAt} did nothing — re-read the scene (or the scene above) before continuing',
        if (unknownReason != null) 'a step\'s effect is unknown: $unknownReason',
      ],
      data: {
        'steps': results,
        'completedSteps': run.completed,
        'totalSteps': steps.length,
        if (run.stoppedAt != null) 'stoppedAt': run.stoppedAt,
        if (run.reason != null) 'reason': run.reason,
        if (run.reason == 'error') 'errorKind': results.last['errorKind'],
        if (overBudget) 'errorKind': GlintErrorKind.budgetExceeded.name,
        if (overBudget)
          'detail':
              'ran ${run.completed} of ${steps.length} step(s) in ${clock.elapsedMilliseconds ~/ 1000} s against a $budgetMs ms budget; step ${run.stoppedAt} (${steps[run.stoppedAt! - 1].tool}) ${interrupted ? 'was interrupted, outcome unknown' : 'did not start'}',
        if (overBudget) 'notRunSteps': notRun,
        if (interrupted) 'interruptedStep': run.stoppedAt,
        'budgetMs': budgetMs,
        'elapsedMs': clock.elapsedMilliseconds,
      },
    );
  }
}
