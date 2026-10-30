import 'action.dart';
import 'input_route.dart';

/// Closed set of failure modes — interaction, perception, MCP all use this.
enum GlintErrorKind {
  // interaction-layer failures
  unsupportedBackendAction,

  /// The iOS bridge is missing, or the selected Xcode is a major glint has not verified.
  unsupportedToolchain,
  backendToolError,
  unresolvedTarget,
  notHittable,
  offViewport,
  geometryResolveError,
  // mcp-layer failures
  sessionNotAttached,
  invalidArgument,
  // `app:` named no attached app, or several
  unknownApp,
  // perception unavailable — app backgrounded / no frame to inspect
  appNotResumed,
  // transport failures
  connectionLost,

  /// The isolate stopped answering: device locked, app suspended by the OS, or paused at a breakpoint.
  appUnresponsive,

  /// The app's VM did not answer in time but the app has drawn frames before: a heavy build or a native surface holding its main thread.
  appBusy,

  /// A physical device stopped answering glint's device input: unplugged, locked before trust, or out of Developer Mode.
  deviceNotConnected,

  /// The phone has no developer disk image mounted, so its input and screen services are missing.
  developerImageMissing,

  /// Another host holds the phone's screen session (Xcode's Device Hub or another viewer).
  deviceBusy,

  /// This kind of device cannot do it (a physical iPhone has no notification list); `data.ability`, `data.instead`.
  notOnThisDevice,

  /// Xcode could not sign a phone build: several teams and none chosen, no certificate, or a bundle id another team owns; `data.teams`.
  signingFailed,

  /// Only part of a text edit landed; `data.delivered` of `data.of`, and nothing was retried.
  inputPartial,
  // the simulator / emulator behind the session is no longer booted
  deviceGone,

  /// Another live glint session is driving the device attach would have picked.
  deviceClaimed,

  /// A destructive tool was pointed at an app or device this session never attached or launched.
  notOwned,

  /// The session is in device mode (no Flutter VM) and the tool needs the widget tree.
  flutterModeRequired,
  // armed-intent failures (§7.3 try/catch)
  targetNeverReady,
  // scroll_to_find specific failures
  targetNotFound,
  scrollLimitReached,
  // bug bucket — should never happen; if it does, it's on us
  internal,
}

/// The `detail` of an [GlintErrorKind.appBusy] reply for a VM that gave no answer within [timeout].
String appBusyDetail(Duration timeout) => 'the app is busy: its VM did not answer within ${timeout.inSeconds}s';

/// Next steps for [GlintErrorKind.appBusy]; [maybeQueued] adds that an input sent earlier may still land.
List<String> appBusyNextSteps({bool maybeQueued = false}) => [
      'wait_for_settle, then retry',
      'if a system alert or sheet is up, get_scene shows it; tap its buttons by text',
      if (maybeQueued)
        'the input was not resent, and the app drops it if it only gets to it now, so get_scene, then send it again',
    ];

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
    this.input,
  })  : ok = true,
        extra = const {},
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
    this.extra = const {},
  })  : ok = false,
        input = null;

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

  /// How a routed backend delivered the input; null for single-path backends.
  final InputReport? input;

  /// Branchable numbers a failure carries (how much landed, which teams).
  final Map<String, Object?> extra;

  /// This success with [input] recorded.
  ActionResult withInput(InputReport input) => ActionResult.success(
        action: action,
        summary: '$summary · ${input.label}',
        physicalCenter: physicalCenter,
        devicePixelRatio: devicePixelRatio,
        painted: painted,
        hittable: hittable,
        warnings: warnings,
        nextSteps: nextSteps,
        input: input,
      );

  Map<String, Object?> toJson() => {
        'action': action.label,
        'ok': ok,
        'summary': summary,
        if (physicalCenter != null) 'physicalCenter': {'x': physicalCenter!.x, 'y': physicalCenter!.y},
        if (devicePixelRatio != null) 'devicePixelRatio': devicePixelRatio,
        if (painted != null) 'painted': painted,
        if (hittable != null) 'hittable': hittable,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (nextSteps.isNotEmpty) 'nextSteps': nextSteps,
        if (error != null) 'error': error,
        if (errorKind != null) 'errorKind': errorKind!.name,
        if (input != null) 'input': input!.toJson(),
        ...extra,
      };
}
