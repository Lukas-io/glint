import 'action.dart';

/// Structured result of running one [Action].
///
/// Shape ported from flutter_network_mcp (`summary` / `nextSteps` /
/// `warnings`): every MCP tool response uses the same envelope so the
/// agent can branch without parsing prose (§D — first-class instruction
/// layer). The MCP-server wrapper in P4 just serialises this verbatim.
class ActionResult {
  ActionResult({
    required this.action,
    required this.ok,
    required this.summary,
    this.physicalCenter,
    this.devicePixelRatio,
    this.painted,
    this.hittable,
    this.warnings = const [],
    this.nextSteps = const [],
    this.error,
    this.errorClass,
  });

  /// The action that was attempted.
  final Action action;

  /// True iff the backend reported success. A `true` value does NOT mean
  /// the agent's intent was satisfied — only that the OS-level event was
  /// dispatched without error. The agent verifies effect via the next
  /// scene read.
  final bool ok;

  /// One human-readable sentence — echoes to the user or to the agent
  /// log line. e.g. `"tapped floating_action_button at (1128, 2502) px"`.
  final String summary;

  /// Physical-pixel point that was actually delivered to the backend.
  /// Present for coordinate-bearing actions (tap, swipe endpoints,
  /// long-press, double-tap); null for typing / hardware buttons.
  final ({int x, int y})? physicalCenter;

  /// DPR observed at resolution time. Useful for the agent to translate
  /// other coordinates if needed.
  final double? devicePixelRatio;

  /// Painted flag from Module B at resolution time. Null if not resolved
  /// (coordinate target, hardware button, type).
  final bool? painted;

  /// Hittable flag from Module B at resolution time. Null if not resolved.
  final bool? hittable;

  /// Non-fatal observations the agent should weigh:
  ///   - "target is painted but not hittable"
  ///   - "settle ceiling hit before frame quiescence"
  ///   - "scene was disposed mid-resolve"
  /// Empty when there's nothing to flag.
  final List<String> warnings;

  /// 1–3 concrete next-step suggestions for the agent. e.g.
  /// `["read scene to confirm counter incremented",
  ///   "if no effect, try CoordinateTarget"]`.
  final List<String> nextSteps;

  /// Set when [ok] is false. Plain message, no stack.
  final String? error;

  /// Set when [ok] is false. Symbolic class name, e.g.
  /// `"UnresolvedTarget"`, `"BackendUnsupported"`, `"NotHittable"`. Lets
  /// the agent branch on cause without parsing [error].
  final String? errorClass;

  Map<String, Object?> toJson() => {
        'action': action.label,
        'ok': ok,
        'summary': summary,
        if (physicalCenter != null)
          'physicalCenter': {'x': physicalCenter!.x, 'y': physicalCenter!.y},
        if (devicePixelRatio != null) 'devicePixelRatio': devicePixelRatio,
        if (painted != null) 'painted': painted,
        if (hittable != null) 'hittable': hittable,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (nextSteps.isNotEmpty) 'nextSteps': nextSteps,
        if (error != null) 'error': error,
        if (errorClass != null) 'errorClass': errorClass,
      };
}
