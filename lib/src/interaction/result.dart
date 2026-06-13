import 'action.dart';

/// Symbolic cause of a failed [ActionResult]. Lets the agent branch on
/// failure mode without parsing prose.
enum ActionFailureKind {
  unsupportedBackendAction,
  backendToolError,
  unresolvedTarget,
  notHittable,
  geometryResolveError,
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
  final ActionFailureKind? errorKind;

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
