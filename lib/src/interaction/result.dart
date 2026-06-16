import 'action.dart';

/// Closed set of failure modes — interaction, perception, MCP all use this.
enum GlintErrorKind {
  // interaction-layer failures
  unsupportedBackendAction,
  backendToolError,
  unresolvedTarget,
  notHittable,
  geometryResolveError,
  // mcp-layer failures
  sessionNotAttached,
  invalidArgument,
  // transport failures
  connectionLost,
  // armed-intent failures (§7.3 try/catch)
  targetNeverReady,
  // bug bucket — should never happen; if it does, it's on us
  internal,
}

class ActionResult {
  ActionResult.success({
    required this.action,
    required this.summary,
    this.physicalCenter,
    this.devicePixelRatio,
    this.painted,
    this.hittable,
    this.warnings = const [],
    this.nextSteps = const [],
  })  : ok = true,
        error = null,
        errorKind = null;

  ActionResult.failure({
    required this.action,
    required this.summary,
    required this.errorKind,
    required this.error,
    this.physicalCenter,
    this.devicePixelRatio,
    this.painted,
    this.hittable,
    this.warnings = const [],
    this.nextSteps = const [],
  }) : ok = false;

  final Action action;
  final bool ok;
  final String summary;
  final ({int x, int y})? physicalCenter;
  final double? devicePixelRatio;
  final bool? painted;
  final bool? hittable;
  final List<String> warnings;
  final List<String> nextSteps;
  final String? error;
  final GlintErrorKind? errorKind;

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
        if (errorKind != null) 'errorKind': errorKind!.name,
      };
}
