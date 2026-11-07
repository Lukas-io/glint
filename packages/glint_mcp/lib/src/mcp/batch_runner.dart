import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import '../../observability.dart' show CallAbandoned, CallProgress, CallTimeboxExceeded;
import '../../perception.dart' show InspectorReadError;
import 'call_diagnostics.dart' show helperFields;
import 'envelope.dart';
import 'explore/recorder.dart' show ExploreCall;
import 'post_action.dart' show shortUnknownReason;
import 'session.dart';
import 'tool.dart';
import 'tools/drag_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/key_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/pinch_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/type_tool.dart';
import 'tools/wait_for_settle_tool.dart';
import 'tools/wait_for_tool.dart';

/// A validated batch step: a step tool name plus that tool's own arguments.
typedef BatchStep = ({String tool, Map<String, Object?> args});

/// Tools a step list may name, shared by batch and record.
const Map<String, GlintTool> kBatchStepTools = {
  'tap': TapTool(),
  'type': TypeTool(),
  'key': KeyTool(),
  'scroll': ScrollTool(),
  'scroll_to_find': ScrollToFindTool(),
  'swipe': SwipeTool(),
  'long_press': LongPressTool(),
  'pinch': PinchTool(),
  'drag': DragTool(),
  'hardware_button': HardwareButtonTool(),
  'wait_for_settle': WaitForSettleTool(),
  'wait_for': WaitForTool(),
};

/// The time the steps in a raw `steps` list may take: each step tool's own ceiling, summed.
Duration stepsCeiling(GlintSession session, Object? raw) {
  if (raw is! List) return Duration.zero;
  var total = Duration.zero;
  for (final step in raw) {
    if (step is! Map) continue;
    final stepArgs = (step['args'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final tool = kBatchStepTools[step['tool']];
    try {
      total += tool?.callCeiling(session, stepArgs) ?? kDefaultCallCeiling;
    } on Object {
      total += kDefaultCallCeiling;
    }
  }
  return total;
}

/// Whether any step in a raw `steps` list acts on the app, by each step tool's own [GlintTool.changesDevice]; an unknown tool counts as changing.
bool stepsChangeDevice(Object? raw) {
  if (raw is! List) return false;
  return raw.any((s) {
    if (s is! Map) return false;
    final tool = kBatchStepTools[s['tool']];
    final args = (s['args'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    return tool == null || tool.changesDevice(args);
  });
}

/// The attached app a step with `app: [target]` runs on; null when none or ambiguous.
AppSession? _stepApp(GlintSession session, String? target) {
  if (target == null) return session.active;
  final matches = session.matchApps(target);
  return matches.length == 1 ? matches.single : null;
}

/// The refusal for the first step aimed at an observe-only app that would change it; null when every step may run.
StructuredResponse? observeRefusalForSteps(GlintSession session, List<BatchStep> steps) {
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final refusal =
        kBatchStepTools[step.tool]!.observeRefusal(_stepApp(session, step.args['app'] as String?), step.args);
    if (refusal != null) return refusal.copyWith(summary: 'step ${i + 1}: ${refusal.summary}');
  }
  return null;
}

/// Steps that resolve a glintId: default to awaitReady so a step can target what the previous step reveals.
const Set<String> kTargetedSteps = {'tap', 'type', 'swipe', 'long_press', 'drag'};

/// The `steps` list schema, shared by batch and record.
Schema batchStepsSchema(int maxSteps, {required String description}) => Schema.list(
      description: description,
      items: ObjectSchema(
        properties: {
          'tool': Schema.string(description: 'Step tool name.'),
          'args': ObjectSchema(description: 'That tool\'s arguments.'),
        },
        required: ['tool'],
      ),
    );

/// Parses a raw `steps` value; the invalidArgument envelope names the offending step.
({List<BatchStep>? steps, StructuredResponse? error}) parseBatchSteps(
  Object? raw, {
  required int maxSteps,
  bool allowEmpty = false,
}) {
  if (raw == null && allowEmpty) return (steps: <BatchStep>[], error: null);
  if (raw is! List || (raw.isEmpty && !allowEmpty)) {
    return (
      steps: null,
      error: StructuredResponse.error(
        summary: 'needs a non-empty steps list',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass steps:[{tool:"tap", args:{glintId:"…"}}, …]'],
      ),
    );
  }
  if (raw.length > maxSteps) {
    return (
      steps: null,
      error: StructuredResponse.error(
        summary: 'takes at most $maxSteps steps (got ${raw.length})',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['split the flow into two calls'],
      ),
    );
  }
  final steps = <BatchStep>[];
  for (var i = 0; i < raw.length; i++) {
    final s = raw[i];
    final tool = s is Map ? s['tool'] as String? : null;
    if (tool == null || !kBatchStepTools.containsKey(tool)) {
      return (
        steps: null,
        error: StructuredResponse.error(
          summary: 'step ${i + 1}: unknown or missing tool "${tool ?? ""}"',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: ['use one of: ${kBatchStepTools.keys.join(", ")}'],
        ),
      );
    }
    final args = (s['args'] as Map?)?.cast<String, Object?>() ?? {};
    if (args['expectChange'] != null && args['expectChange'] is! bool) {
      return (
        steps: null,
        error: StructuredResponse.error(
          summary: 'step ${i + 1}: expectChange must be true or false',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['pass expectChange:false in the step args when it is fine for the step to change nothing'],
        ),
      );
    }
    steps.add((tool: tool, args: args));
  }
  return (steps: steps, error: null);
}

/// One executed step: the reply plus when it fired and how long it took.
class StepOutcome {
  StepOutcome({
    required this.index,
    required this.tool,
    required this.args,
    required this.response,
    required this.startedAt,
    required this.elapsedMs,
    this.interrupted = false,
  });

  final int index;
  final String tool;
  final Map<String, Object?> args;
  final StructuredResponse response;
  final DateTime startedAt;
  final int elapsedMs;

  /// The step was still running when the batch budget ended, so whether it took effect is unknown.
  final bool interrupted;

  bool? get changed => switch (response.data?['changed']) { final bool b => b, _ => null };
  String? get changeCategory => response.data?['changeCategory'] as String?;

  /// Whether the step's action was delivered but its effect could not be read in time.
  bool get changeUnknown => response.data?['changed'] == 'unknown';

  String? get unknownReason => response.data?['unknownReason'] as String?;
  bool get isError => response.isError;

  /// The per-step reply JSON (batch's fields); [origin] adds firedAtMs relative to it.
  Map<String, Object?> toJson({DateTime? origin}) => {
        'step': index,
        'tool': tool,
        if (args['app'] != null) 'app': args['app'],
        if (args['expectChange'] == false) 'expectChange': false,
        'ok': !isError,
        if (interrupted) 'interrupted': true,
        'elapsedMs': elapsedMs,
        if (origin != null) 'firedAtMs': startedAt.difference(origin).inMilliseconds,
        'summary': shortSummary(response.summary),
        if (changed != null) 'changed': changed,
        if (changeUnknown) ...{'changed': 'unknown', 'unknownReason': shortUnknownReason(unknownReason)},
        if (changeCategory != null) 'changeCategory': changeCategory,
        if (isError) 'errorKind': response.data?['errorKind'],
        if (isError && response.data?['detail'] != null) 'detail': response.data?['detail'],
        if (isError && response.nextSteps.isNotEmpty) 'nextSteps': response.nextSteps,
        if (response.warnings.isNotEmpty) 'warnings': response.warnings,
      };

  /// The one-line prose batch prints per step.
  String line({DateTime? origin}) {
    final fired = origin == null ? '' : ', fired at ${startedAt.difference(origin).inMilliseconds} ms';
    final app = args['app'];
    return '$index. ${app == null ? '' : '[$app] '}$tool ${stepTarget(args)} → '
        '${isError ? "FAIL ${response.data?['errorKind']}: " : ""}'
        '${shortSummary(response.summary)}'
        '${changeUnknown ? " · changed unknown: $unknownReason" : changeCategory != null ? " · $changeCategory" : ""}'
        ' [${elapsedMs}ms]$fired';
  }
}

/// Outcomes plus why and where the run stopped (null reason = ran all).
class BatchRun {
  BatchRun({required this.outcomes, this.reason, this.stoppedAt});
  final List<StepOutcome> outcomes;
  final String? reason;
  final int? stoppedAt;

  int get completed =>
      stoppedAt == null ? outcomes.length : (reason == 'error' || reason == 'budget' ? stoppedAt! - 1 : stoppedAt!);
}

int _batchSeq = 0;

/// Runs [steps] in order with batch's arg defaults, logging each under its own tool name; a step with `expectChange:false` never stops the run on `changed:false`. With a [budget] each step gets at most what is left of it: a run out of time stops with reason `budget` before the next step, or interrupts the running one (`StepOutcome.interrupted`). Rethrows [SessionNotAttachedError].
Future<BatchRun> runBatchSteps(
  GlintSession session,
  List<BatchStep> steps, {
  required bool stopOnNoChange,
  Duration? budget,
  void Function(int index, String tool)? onStepStart,
  MetaWithProgressToken? meta,
}) async {
  final clock = Stopwatch()..start();
  final outcomes = <StepOutcome>[];
  String? reason;
  int? stoppedAt;
  CallProgress.current?.batchId = 'b${++_batchSeq}';
  for (var i = 0; i < steps.length; i++) {
    if (budget != null && i > 0 && budget - clock.elapsed < _minStepTime) {
      reason = 'budget';
      stoppedAt = i + 1;
      break;
    }
    CallProgress.enter('batch step ${i + 1} of ${steps.length}: ${steps[i].tool}', key: 'batch');
    CallProgress.stepLabel('step ${i + 1}/${steps.length}: ${steps[i].tool}');
    CallProgress.note(null);
    final step = steps[i];
    onStepStart?.call(i + 1, step.tool);
    final tool = kBatchStepTools[step.tool]!;
    final start = DateTime.now();
    final since = CallProgress.current?.mark();
    Object? failure;
    final own = CallToolRequest(
        name: step.tool,
        arguments: {...step.args}
          ..remove('app')
          ..remove('expectChange'));
    final aliasWarnings = <String>[];
    final invalid = GlintTool.checkArguments(tool.definition, own, warnings: aliasWarnings);
    if (budget != null && invalid == null && step.tool == 'wait_for') {
      holdWaitToBudget(own.arguments!, budget - clock.elapsed, aliasWarnings);
    }
    final ownArgs = own.arguments ?? const <String, Object?>{};
    final stepArgs = {
      ...ownArgs,
      if (kTargetedSteps.contains(step.tool) && !ownArgs.containsKey('awaitReady')) 'awaitReady': true,
      if (step.tool != 'hardware_button' &&
          step.tool != 'wait_for_settle' &&
          step.tool != 'wait_for' &&
          !ownArgs.containsKey('returnScene'))
        'returnScene': true,
      'fetchScene': false,
    };
    final request = CallToolRequest(name: step.tool, arguments: stepArgs, meta: meta);
    final left = budget == null ? null : budget - clock.elapsed;
    final ceiling = _stepCeiling(tool, session, stepArgs);
    final budgetLimited = left != null && left < ceiling;
    final limit = budgetLimited ? left : (budget == null ? null : ceiling);
    Future<StructuredResponse> boxed(Future<StructuredResponse> Function() run) =>
        limit == null ? run() : CallProgress.timeboxed(limit, run);
    var interrupted = false;
    final appTarget = step.args['app'] as String?;
    final matches = appTarget == null ? null : session.matchApps(appTarget);
    StructuredResponse r;
    ExploreCall? call;
    final app = matches != null && matches.length == 1 ? matches.single : session.active;
    try {
      if (invalid != null) {
        r = invalid;
      } else if (matches == null) {
        r = tool.observeRefusal(session.active, stepArgs) ??
            await boxed(() => (call = ExploreCall()).run(() async => await tool.handle(session, request)));
      } else if (matches.length != 1) {
        r = GlintTool.unknownAppResponse(session, appTarget!, matches);
      } else {
        r = tool.observeRefusal(matches.single, stepArgs) ??
            await session.withApp(matches.single,
                () => boxed(() => (call = ExploreCall()).run(() async => await tool.handle(session, request))));
      }
    } on SessionNotAttachedError {
      rethrow;
    } on CallTimeboxExceeded catch (e) {
      interrupted = true;
      r = budgetLimited ? _interruptedByBudget(step.tool, e) : _interruptedByCeiling(step.tool, e);
    } on CallAbandoned {
      rethrow;
    } on ProcessTimeoutError catch (e) {
      r = StructuredResponse.backendError('${step.tool}: ${e.phase} timed out', e);
    } on InspectorReadError catch (e) {
      r = await tool.noFrameResponse(session, e);
    } on Object catch (e) {
      failure = e;
      r = StructuredResponse.error(
        summary: '${step.tool} failed',
        errorKind: GlintErrorKind.internal,
        detail: '$e',
      );
    }
    CallProgress.note(null);
    r = r.addWarnings(aliasWarnings);
    tool.logCall(session, request, r, start,
        app: app, call: call, failure: failure, since: since, batchStep: i + 1, helpers: await helperFields(start));
    outcomes.add(StepOutcome(
      index: i + 1,
      tool: step.tool,
      args: step.args,
      response: r,
      startedAt: start,
      elapsedMs: DateTime.now().difference(start).inMilliseconds,
      interrupted: interrupted,
    ));
    if (r.isError) {
      reason = interrupted && budgetLimited ? 'budget' : 'error';
      stoppedAt = i + 1;
      break;
    }
    final expectsChange = step.args['expectChange'] != false;
    if (stopOnNoChange && expectsChange && r.data?['changed'] == false) {
      reason = 'noChange';
      stoppedAt = i + 1;
      break;
    }
  }
  CallProgress.stepLabel(null);
  return BatchRun(outcomes: outcomes, reason: reason, stoppedAt: stoppedAt);
}

/// Least time a step may be started with, so a nearly spent budget stops the batch instead of cutting a step short.
const Duration _minStepTime = Duration(seconds: 1);

Duration _stepCeiling(GlintTool tool, GlintSession session, Map<String, Object?> args) {
  try {
    return tool.callCeiling(session, args);
  } on Object {
    return kDefaultCallCeiling;
  }
}

/// Room kept at the end of the budget for a held `wait_for` to read once more and reply.
const Duration _waitMargin = Duration(milliseconds: 1500);

/// Holds a `wait_for` step's timeout to what is [left] of the batch budget minus [_waitMargin], so it fails cleanly before the step is cut off.
void holdWaitToBudget(Map<String, Object?> args, Duration left, List<String> warnings) {
  final raw = args['timeoutMs'];
  final asked = raw is num ? raw.toInt() : 15000;
  final room = (left - _waitMargin).inMilliseconds;
  final allowed = room < 100 ? 100 : room;
  if (asked <= allowed) return;
  args['timeoutMs'] = allowed;
  warnings.add('wait_for timeoutMs held to $allowed ms by the batch budget');
}

String _interruptDetail(CallTimeboxExceeded e) =>
    'ran ${(e.elapsedMs / 1000).toStringAsFixed(1)} s of a ${(e.limit.inMilliseconds / 1000).toStringAsFixed(1)} s limit; '
    'last phase "${e.phase}"; phases: ${e.trail.join(' > ')}; ${e.unwound ? 'the step has stopped and its subprocesses were stopped' : 'the step had not stopped after the wait (a gesture already handed to the device runs to its end, so get_scene a moment later)'}';

StructuredResponse _interruptedByBudget(String tool, CallTimeboxExceeded e) => StructuredResponse.error(
      summary: 'interrupted: the batch budget ran out while $tool was running, so whether it took effect is unknown',
      errorKind: GlintErrorKind.budgetExceeded,
      detail: _interruptDetail(e),
      nextSteps: const ['get_scene shows the screen as it is now; check it before repeating the step'],
    );

StructuredResponse _interruptedByCeiling(String tool, CallTimeboxExceeded e) => StructuredResponse.error(
      summary: '$tool did not finish within ${e.limit.inSeconds}s and was cancelled',
      errorKind: GlintErrorKind.toolTimeout,
      detail: _interruptDetail(e),
      nextSteps: const ['get_scene shows the screen as it is now; check it before repeating the step'],
    );

/// First line of a summary, capped for compact per-step display.
String shortSummary(String s) {
  final first = s.split('\n').first.trim();
  return first.length > 120 ? '${first.substring(0, 119)}…' : first;
}

/// The most informative argument for a step's one-line label.
String stepTarget(Map<String, Object?> a) {
  for (final k in const [
    'glintId', 'focus', 'targetGlintId', 'targetTextContent', //
    'text', 'fromGlintId', 'direction', 'button', 'key',
  ]) {
    final v = a[k];
    if (v != null) {
      return '$k=${v is String && v.length > 30 ? '${v.substring(0, 29)}…' : v}';
    }
  }
  return '';
}
