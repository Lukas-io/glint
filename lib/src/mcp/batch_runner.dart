import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import 'envelope.dart';
import 'session.dart';
import 'tool.dart';
import 'tools/drag_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/key_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/type_tool.dart';
import 'tools/wait_for_settle_tool.dart';

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
  'drag': DragTool(),
  'hardware_button': HardwareButtonTool(),
  'wait_for_settle': WaitForSettleTool(),
};

/// Steps that resolve a glintId: default to awaitReady so a step can target what the previous step reveals.
const Set<String> kTargetedSteps = {'tap', 'type', 'swipe', 'long_press', 'drag'};

/// The `steps` list schema, shared by batch and record.
Schema batchStepsSchema(int maxSteps, {required String description}) =>
    Schema.list(
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
  });

  final int index;
  final String tool;
  final Map<String, Object?> args;
  final StructuredResponse response;
  final DateTime startedAt;
  final int elapsedMs;

  bool? get changed => response.data?['changed'] as bool?;
  String? get changeCategory => response.data?['changeCategory'] as String?;
  bool get isError => response.isError;

  /// The per-step reply JSON (batch's fields); [origin] adds firedAtMs relative to it.
  Map<String, Object?> toJson({DateTime? origin}) => {
        'step': index,
        'tool': tool,
        'ok': !isError,
        'elapsedMs': elapsedMs,
        if (origin != null)
          'firedAtMs': startedAt.difference(origin).inMilliseconds,
        'summary': shortSummary(response.summary),
        if (changed != null) 'changed': changed,
        if (changeCategory != null) 'changeCategory': changeCategory,
        if (isError) 'errorKind': response.data?['errorKind'],
        if (isError && response.data?['detail'] != null)
          'detail': response.data?['detail'],
        if (isError && response.nextSteps.isNotEmpty)
          'nextSteps': response.nextSteps,
        if (response.warnings.isNotEmpty) 'warnings': response.warnings,
      };

  /// The one-line prose batch prints per step.
  String line({DateTime? origin}) {
    final fired = origin == null
        ? ''
        : ', fired at ${startedAt.difference(origin).inMilliseconds} ms';
    return '$index. $tool ${stepTarget(args)} → '
        '${isError ? "FAIL ${response.data?['errorKind']}: " : ""}'
        '${shortSummary(response.summary)}'
        '${changeCategory != null ? " · $changeCategory" : ""}'
        ' [${elapsedMs}ms]$fired';
  }
}

/// Outcomes plus why and where the run stopped (null reason = ran all).
class BatchRun {
  BatchRun({required this.outcomes, this.reason, this.stoppedAt});
  final List<StepOutcome> outcomes;
  final String? reason;
  final int? stoppedAt;

  int get completed => stoppedAt == null
      ? outcomes.length
      : (reason == 'error' ? stoppedAt! - 1 : stoppedAt!);
}

/// Runs [steps] in order with batch's arg defaults, logging each under its own tool name. Rethrows [SessionNotAttachedError].
Future<BatchRun> runBatchSteps(
  GlintSession session,
  List<BatchStep> steps, {
  required bool stopOnNoChange,
  void Function(int index, String tool)? onStepStart,
}) async {
  final outcomes = <StepOutcome>[];
  String? reason;
  int? stoppedAt;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    onStepStart?.call(i + 1, step.tool);
    final stepArgs = {
      ...step.args,
      if (kTargetedSteps.contains(step.tool) &&
          !step.args.containsKey('awaitReady'))
        'awaitReady': true,
      if (step.tool != 'hardware_button' && step.tool != 'wait_for_settle')
        'returnScene': true,
      'fetchScene': false,
    }..remove('app');
    final tool = kBatchStepTools[step.tool]!;
    final start = DateTime.now();
    StructuredResponse r;
    try {
      r = await tool.handle(
          session, CallToolRequest(name: step.tool, arguments: stepArgs));
    } on SessionNotAttachedError {
      rethrow;
    } on Object catch (e) {
      r = StructuredResponse.error(
        summary: '${step.tool} failed',
        errorKind: GlintErrorKind.internal,
        detail: '$e',
      );
    }
    tool.logCall(session,
        CallToolRequest(name: step.tool, arguments: stepArgs), r, start);
    outcomes.add(StepOutcome(
      index: i + 1,
      tool: step.tool,
      args: step.args,
      response: r,
      startedAt: start,
      elapsedMs: DateTime.now().difference(start).inMilliseconds,
    ));
    if (r.isError) {
      reason = 'error';
      stoppedAt = i + 1;
      break;
    }
    if (stopOnNoChange && (r.data?['changed'] as bool?) == false) {
      reason = 'noChange';
      stoppedAt = i + 1;
      break;
    }
  }
  return BatchRun(outcomes: outcomes, reason: reason, stoppedAt: stoppedAt);
}

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
