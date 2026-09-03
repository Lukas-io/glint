import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../semantic.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import 'drag_tool.dart';
import 'hardware_button_tool.dart';
import 'long_press_tool.dart';
import 'scroll_to_find_tool.dart';
import 'scroll_tool.dart';
import 'swipe_tool.dart';
import 'tap_tool.dart';
import 'type_tool.dart';
import 'wait_for_settle_tool.dart';

/// `batch` — run an ordered list of gesture steps server-side in one call.
/// Each step settles like a normal call; the batch stops at the first error
/// or (by default) the first step that changed nothing, and returns one
/// final scene. Cuts a known N-step flow from N round trips to one.
class BatchTool extends GlintTool {
  const BatchTool();

  static const Map<String, GlintTool> _stepTools = {
    'tap': TapTool(),
    'type': TypeTool(),
    'scroll': ScrollTool(),
    'scroll_to_find': ScrollToFindTool(),
    'swipe': SwipeTool(),
    'long_press': LongPressTool(),
    'drag': DragTool(),
    'hardware_button': HardwareButtonTool(),
    'wait_for_settle': WaitForSettleTool(),
  };

  /// Steps that resolve a glintId: default to `awaitReady:true` so a step can
  /// target what the previous step is about to reveal.
  static const _targeted = {'tap', 'type', 'swipe', 'long_press', 'drag'};

  static const int _maxSteps = 20;

  @override
  Tool get definition => Tool(
        name: 'batch',
        description:
            'Run several steps in ONE call: steps:[{tool, args}] over '
            '${_stepTools.keys.join(", ")}. Each step settles like a normal '
            'call and reports changed/changeCategory; the batch stops at the '
            'first error or, with stopOnNoChange (default true), the first '
            'step that changed nothing, then returns per-step results and the '
            'final scene. Targeted steps default to awaitReady:true so a step '
            'may name an id the previous step reveals. Use for a known '
            'sequence (fill a form, walk a wizard); use single calls when the '
            'next move depends on what you see.',
        inputSchema: ObjectSchema(
          properties: {
            'steps': Schema.list(
              description:
                  'Ordered steps, each {tool: "<name>", args: {…}} with the '
                  'same args the tool takes on its own. Max $_maxSteps.',
              items: ObjectSchema(
                properties: {
                  'tool': Schema.string(description: 'Step tool name.'),
                  'args': ObjectSchema(description: 'That tool\'s arguments.'),
                },
                required: ['tool'],
              ),
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
    final rawSteps = args['steps'];
    final stopOnNoChange = (args['stopOnNoChange'] as bool?) ?? true;
    final returnScene = (args['returnScene'] as bool?) ?? true;

    if (rawSteps is! List || rawSteps.isEmpty) {
      return StructuredResponse.error(
        summary: 'batch needs a non-empty steps list',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass steps:[{tool:"tap", args:{glintId:"…"}}, …]'],
      );
    }
    if (rawSteps.length > _maxSteps) {
      return StructuredResponse.error(
        summary: 'batch takes at most $_maxSteps steps (got ${rawSteps.length})',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['split the flow into two batches'],
      );
    }
    final steps = <({String tool, Map<String, Object?> args})>[];
    for (var i = 0; i < rawSteps.length; i++) {
      final s = rawSteps[i];
      final tool = s is Map ? s['tool'] as String? : null;
      if (tool == null || !_stepTools.containsKey(tool)) {
        return StructuredResponse.error(
          summary: 'step ${i + 1}: unknown or missing tool "${tool ?? ""}"',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: ['use one of: ${_stepTools.keys.join(", ")}'],
        );
      }
      final stepArgs = (s['args'] as Map?)?.cast<String, Object?>() ?? {};
      steps.add((tool: tool, args: stepArgs));
    }

    final results = <Map<String, Object?>>[];
    final lines = <String>[];
    String? reason;
    int? stoppedAt;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepArgs = {
        ...step.args,
        if (_targeted.contains(step.tool) && !step.args.containsKey('awaitReady'))
          'awaitReady': true,
        if (step.tool != 'hardware_button' && step.tool != 'wait_for_settle')
          'returnScene': true,
        'fetchScene': false,
      }..remove('app');
      final tool = _stepTools[step.tool]!;
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
      tool.logCall(
          session, CallToolRequest(name: step.tool, arguments: stepArgs), r, start);
      final changed = r.data?['changed'] as bool?;
      final category = r.data?['changeCategory'] as String?;
      results.add({
        'step': i + 1,
        'tool': step.tool,
        'ok': !r.isError,
        'summary': _short(r.summary),
        if (changed != null) 'changed': changed,
        if (category != null) 'changeCategory': category,
        if (r.isError) 'errorKind': r.data?['errorKind'],
        if (r.isError && r.data?['detail'] != null) 'detail': r.data?['detail'],
        if (r.isError && r.nextSteps.isNotEmpty) 'nextSteps': r.nextSteps,
        if (r.warnings.isNotEmpty) 'warnings': r.warnings,
      });
      lines.add('${i + 1}. ${step.tool} ${_target(step.args)} → '
          '${r.isError ? "FAIL ${r.data?['errorKind']}: " : ""}${_short(r.summary)}'
          '${category != null ? " · $category" : ""}');
      if (r.isError) {
        reason = 'error';
        stoppedAt = i + 1;
        break;
      }
      if (stopOnNoChange && changed == false) {
        reason = 'noChange';
        stoppedAt = i + 1;
        break;
      }
    }

    final completed = stoppedAt == null
        ? steps.length
        : (reason == 'error' ? stoppedAt - 1 : stoppedAt);
    String? scene;
    if (returnScene && !session.isDeviceMode) {
      try {
        scene = await session.withScene(
            (s) async => const PlainTextSceneRenderer().render(s));
      } on Object {
        scene = null;
      }
    }

    final header = stoppedAt == null
        ? 'ran ${steps.length}/${steps.length} step(s)'
        : reason == 'error'
            ? 'stopped at step $stoppedAt of ${steps.length} (error)'
            : 'stopped at step $stoppedAt of ${steps.length}: nothing changed';
    return StructuredResponse(
      summary: [
        header,
        ...lines,
        if (scene != null) '',
        if (scene != null) '--- scene after batch ---',
        if (scene != null) scene.trimRight(),
      ].join('\n'),
      isError: reason == 'error',
      nextSteps: [
        if (reason == 'error')
          'read the failing step\'s detail above, fix its args, and resume from step $stoppedAt',
        if (reason == 'noChange')
          'step $stoppedAt did nothing — re-read the scene (or the scene above) before continuing',
      ],
      data: {
        'steps': results,
        'completedSteps': completed,
        'totalSteps': steps.length,
        if (stoppedAt != null) 'stoppedAt': stoppedAt,
        if (reason != null) 'reason': reason,
        if (reason == 'error') 'errorKind': results.last['errorKind'],
      },
    );
  }

  String _short(String s) {
    final first = s.split('\n').first.trim();
    return first.length > 120 ? '${first.substring(0, 119)}…' : first;
  }

  String _target(Map<String, Object?> a) {
    for (final k in const ['glintId', 'focus', 'targetGlintId', 'targetTextContent', 'text', 'fromGlintId', 'direction', 'button']) {
      final v = a[k];
      if (v != null) return '$k=${v is String && v.length > 30 ? '${v.substring(0, 29)}…' : v}';
    }
    return '';
  }
}
