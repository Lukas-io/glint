import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart' show InspectorReadError, appBusyCause, suggestIds;
import '../../runtime.dart';
import 'envelope.dart';
import 'explore/recorder.dart' show ExploreCall;
import 'session.dart';
import 'tool_args.dart';
import 'tools/app_logs_tool.dart';
import 'tools/breakpoint_tool.dart';
import 'tools/attach_tool.dart';
import 'tools/batch_tool.dart';
import 'tools/record_tool.dart';
import 'tools/config_tool.dart';
import 'tools/device_tool.dart';
import 'tools/drag_tool.dart';
import 'tools/explore_tool.dart';
import 'tools/get_scene_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/hot_reload_tool.dart';
import 'tools/kill_app_tool.dart';
import 'tools/logs_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/pinch_tool.dart';
import 'tools/location_tool.dart';
import 'tools/map_tool.dart';
import 'tools/media_tool.dart';
import 'tools/notifications_tool.dart';
import 'tools/sensors_tool.dart';
import 'tools/report_issue_tool.dart';
import 'tools/resolve_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/session_tool.dart';
import 'tools/shutdown_sim_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/telemetry_tool.dart';
import 'tools/key_tool.dart';
import 'tools/type_tool.dart';
import 'tools/wait_for_settle_tool.dart';
import 'tools/wait_for_tool.dart';
import 'tools/watch_tool.dart';

/// One MCP tool. Subclasses provide a [definition] + [handle]; [invoke]
/// wraps both with the envelope conversion + uniform error catch.
abstract class GlintTool {
  const GlintTool();

  Tool get definition;

  /// [definition] plus the shared `app` routing arg — what the server registers.
  Tool get registeredDefinition => routesByApp ? withAppArg(definition) : definition;

  /// Tools that give `app` their own meaning (attach) opt out of routing.
  bool get routesByApp => true;

  /// Whether `app:"*"` means every attached app and reaches [handle] unrouted.
  bool get acceptsAllApps => false;

  /// Whether a call with [args] acts on the app or its device, which an app attached with observe:true refuses; true unless a tool says it only reads.
  bool changesDevice(Map<String, Object?> args) => true;

  /// Whether the call's `op` (or [defaultOp]) is outside [readOps].
  static bool opChangesDevice(Map<String, Object?> args, {required Set<String> readOps, required String defaultOp}) =>
      !readOps.contains((args['op'] as String?) ?? defaultOp);

  /// The refusal for a call on an observe-only [app] that would change it; null when the call may run.
  StructuredResponse? observeRefusal(AppSession? app, Map<String, Object?> args) {
    if (app == null || !app.observeOnly || !changesDevice(args)) return null;
    return StructuredResponse.error(
      summary: '${definition.name} is refused: ${app.label} is attached with observe:true, read only',
      errorKind: GlintErrorKind.observeOnly,
      detail: 'the app was attached with observe:true; it allows get_scene, logs, app_logs, screenshots, watch, '
          'wait_for and resolve, and refuses anything that changes the app or its device',
      nextSteps: [
        'to drive it, attach again without observe (attach app:"${app.label}"), once nobody else is using the device',
        'to keep observing: get_scene, app_logs, watch op:events',
      ],
    );
  }

  /// Adds the optional `app` property every routed tool accepts.
  static Tool withAppArg(Tool tool) {
    final raw = tool as Map<String, Object?>;
    final schema = Map<String, Object?>.from(raw['inputSchema'] as Map<String, Object?>? ?? const {});
    final props = Map<String, Object?>.from((schema['properties'] as Map?)?.cast<String, Object?>() ?? const {});
    props['app'] = Schema.string(
      description:
          'Target app when several are attached (device id, name, package or simulator). Default: the active one.',
    );
    return Tool.fromMap({
      ...raw,
      'inputSchema': {...schema, 'type': 'object', 'properties': props},
    });
  }

  /// Coerces numeric and true/false strings in typed top-level fields in place, then checks top-level fields against [tool]'s schema (nested shapes are the tool's own to explain); null when valid.
  static StructuredResponse? checkArguments(Tool tool, CallToolRequest request) {
    final args = request.arguments;
    final props = tool.inputSchema.properties ?? const {};
    if (args != null) {
      for (final MapEntry(:key, value: schema) in props.entries) {
        final raw = args[key];
        if (raw is! String) continue;
        final coerced = switch (schema.type) {
          JsonType.int => looseInt(raw),
          JsonType.num => looseNum(raw),
          JsonType.bool => looseBool(raw),
          _ => null,
        };
        if (coerced != null) args[key] = coerced;
      }
    }
    if (args != null) aliasTargetArg(args, props.keys);
    final unknown = [
      for (final k in args?.keys ?? const <String>[])
        if (!props.containsKey(k)) k,
    ];
    if (unknown.isNotEmpty) {
      return StructuredResponse.error(
        summary: '${tool.name}: unknown argument${unknown.length == 1 ? '' : 's'} '
            '${unknown.join(", ")}',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: [
          for (final k in unknown)
            if (closestArgName(k, props.keys) case final near?) 'use $near instead of $k',
          'accepted fields: ${props.keys.join(", ")}',
        ],
      );
    }
    final errors = tool.inputSchema.validate(args ?? const {}).where((e) => e.path.length <= 1).toList();
    if (errors.isEmpty) return null;
    return StructuredResponse.error(
      summary: '${tool.name}: invalid arguments',
      errorKind: GlintErrorKind.invalidArgument,
      detail: errors
          .map((e) => '${e.path.isEmpty ? 'arguments' : e.path.join('.')}: ${e.details ?? e.error.name}')
          .join('\n'),
      nextSteps: [
        'fix the arguments named in detail; accepted fields: '
            '${props.keys.join(", ")}',
      ],
    );
  }

  /// Tools whose target argument has its own name (`focus`, `targetGlintId`) also take `glintId`, renamed here before validation.
  static void aliasTargetArg(Map<String, Object?> args, Iterable<String> accepted) {
    if (!args.containsKey('glintId') || accepted.contains('glintId')) return;
    for (final name in const ['focus', 'targetGlintId']) {
      if (accepted.contains(name) && !args.containsKey(name)) {
        args[name] = args.remove('glintId');
        return;
      }
    }
  }

  /// The accepted argument name an unknown [name] most likely meant: containment first (glintId → targetGlintId), then a small edit distance.
  static String? closestArgName(String name, Iterable<String> accepted) {
    final lower = name.toLowerCase();
    for (final a in accepted) {
      final l = a.toLowerCase();
      if (l.contains(lower) || lower.contains(l)) return a;
    }
    final near = suggestIds(accepted, name, max: 1);
    return near.isEmpty ? null : near.single;
  }

  FutureOr<StructuredResponse> handle(
    GlintSession session,
    CallToolRequest request,
  );

  /// How long a call with [args] may run before glint cancels it and answers `toolTimeout`; tools that wait on request raise it.
  Duration callCeiling(GlintSession session, Map<String, Object?> args) => kDefaultCallCeiling;

  /// A ceiling for a call that waits up to [waitMs] on request, plus [slackSec] for the work around the wait.
  static Duration ceilingFor(int waitMs, {int slackSec = 30}) {
    final ceiling = Duration(milliseconds: waitMs + slackSec * 1000);
    return ceiling < kDefaultCallCeiling ? kDefaultCallCeiling : ceiling;
  }

  /// A ceiling for a gesture or typing call: the ready wait it may do plus [extraMs] of its own work.
  static Duration actionCeiling(GlintSession session, Map<String, Object?> args, {int extraMs = 0}) =>
      ceilingFor((argInt(args, 'readyTimeoutMs') ?? session.config.readyTimeoutMs) + extraMs, slackSec: 45);

  /// How often a running call tells the client what it is doing.
  static const Duration heartbeatEvery = Duration(seconds: 10);

  Duration _safeCeiling(GlintSession session, Map<String, Object?> args) {
    try {
      return callCeiling(session, args);
    } on Object {
      return kDefaultCallCeiling;
    }
  }

  /// Runs [handle] under a time ceiling and a progress heartbeat; a call that outlives its ceiling is cancelled and answered with `toolTimeout`.
  Future<CallToolResult> invoke(
    GlintSession session,
    CallToolRequest request,
  ) async {
    final call = CallProgress(
      tool: definition.name,
      token: request.meta?.progressToken,
      send: session.rawProgressNotifier,
    );
    final ceiling = _safeCeiling(session, request.arguments ?? const {});
    final answer = Completer<CallToolResult>();
    final start = DateTime.now();
    unawaited(call.run(() => _invoke(session, request)).then((result) {
      if (!answer.isCompleted) answer.complete(result);
    }, onError: (Object e, StackTrace st) {
      if (!answer.isCompleted) answer.completeError(e, st);
    }));
    call.watch(
      ceiling: ceiling,
      heartbeatEvery: heartbeatEvery,
      onCeiling: () {
        if (answer.isCompleted) return;
        final response = _timeoutResponse(call, ceiling, request.arguments ?? const {});
        call.run(() => logCall(session, request, response, start));
        call.abandon();
        answer.complete(response.toCallResult());
      },
    );
    try {
      return await answer.future;
    } finally {
      call.stop();
    }
  }

  /// The reply for a call cancelled at its [ceiling]: where it was stuck, how long, and what to do.
  StructuredResponse _timeoutResponse(CallProgress call, Duration ceiling, Map<String, Object?> args) {
    final elapsedMs = call.clock.elapsedMilliseconds;
    final stuck = call.phase;
    final stopped = call.runningProcesses;
    return StructuredResponse.error(
      summary: '${definition.name} did not finish within ${ceiling.inSeconds}s; stuck in "$stuck" for '
          '${(call.phaseMs / 1000).toStringAsFixed(1)}s',
      errorKind: GlintErrorKind.toolTimeout,
      detail: '${definition.name} ran ${(elapsedMs / 1000).toStringAsFixed(1)}s of awake time against a '
          '${ceiling.inSeconds}s ceiling and was cancelled; phases: ${call.trail.join(' > ')}; '
          '${stopped.isEmpty ? 'no subprocess was running' : 'stopped: ${stopped.join(', ')}'}',
      nextSteps: [
        if (changesDevice(args))
          'the action may already have landed: `get_scene` shows the current state before you act again',
        'toolTimeout: nothing new starts for this call, but input already delivered to the app or device is not undone',
        'retry once; the session stays usable',
        'if it repeats, `device op:screenshot` shows whether the device or simulator is frozen; reboot it or `attach` again',
      ],
    ).mergeData({
      'phase': stuck,
      'elapsedMs': elapsedMs,
      'ceilingMs': ceiling.inMilliseconds,
      'scope': 'tool',
      'phases': call.trail,
    });
  }

  /// Error-bubbling contract:
  ///   - [SessionNotAttachedError] → structured `sessionNotAttached` envelope.
  ///   - Any other throw from [handle] (including [RPCError] from a dropped
  ///     VM connection) → structured `internal` envelope with the detail.
  /// Nothing escapes; the wire-level RPC error is reserved for true
  /// protocol failures (unknown tool, server doesn't support tools, etc.)
  /// and is handled by dart_mcp's [ToolsSupport.callTool].
  Future<CallToolResult> _invoke(
    GlintSession session,
    CallToolRequest request,
  ) async {
    final start = DateTime.now();
    final invalid = checkArguments(registeredDefinition, request);
    if (invalid != null) {
      logCall(session, request, invalid, start);
      return invalid.toCallResult();
    }
    StructuredResponse response;
    ExploreCall? call;
    final requested = routesByApp ? (request.arguments?['app'] as String?) : null;
    final target = acceptsAllApps && requested == '*' ? null : requested;
    var app = session.active;
    if (session.active?.device.id case final id?) DeviceClaims().touch(id);
    try {
      if (target == null) {
        response = observeRefusal(app, request.arguments ?? const {}) ??
            await (call = ExploreCall()).run(() async => await handle(session, request));
      } else {
        final matches = session.matchApps(target);
        if (matches.length != 1) {
          response = unknownAppResponse(session, target, matches);
        } else {
          app = matches.single;
          response = observeRefusal(app, request.arguments ?? const {}) ??
              await session.withApp(
                  matches.single, () => (call = ExploreCall()).run(() async => await handle(session, request)));
        }
      }
    } on SessionNotAttachedError catch (e) {
      final pooled = session.apps;
      final active = session.active;
      response = active != null && active.deviceMode
          ? flutterModeRequiredResponse(definition.name, active, e)
          : StructuredResponse.error(
              summary: pooled.isEmpty
                  ? 'glint is not attached to a Flutter app yet'
                  : 'no active app — ${pooled.length} attached app(s) to pick from',
              errorKind: GlintErrorKind.sessionNotAttached,
              detail: e.toString(),
              nextSteps: pooled.isEmpty
                  ? const ['call `attach` (no args) to discover and connect the running app']
                  : [
                      for (final a in pooled) 'attach app:"${a.label}"  (${a.deviceName ?? a.id})',
                    ],
            );
    } on ProcessTimeoutError catch (e) {
      response = StructuredResponse.backendError('${definition.name}: ${e.phase} timed out', e);
    } on CallAbandoned {
      response = StructuredResponse.error(
        summary: '${definition.name} was cancelled at its time ceiling',
        errorKind: GlintErrorKind.toolTimeout,
        nextSteps: const ['retry once; `get_scene` shows the current state'],
      );
    } on RuntimeConnectionLostError catch (e) {
      response = await _connectionLostResponse(session, e);
    } on RuntimeUnresponsiveError catch (e) {
      response = await _unresponsiveResponse(session, e);
    } on IosToolchainBlocked catch (e) {
      response = StructuredResponse.toolchainBlocked(e);
    } on InspectorReadError catch (e) {
      response =
          looksLikeConnectionLoss(e) ? await _connectionLostResponse(session, e) : await noFrameResponse(session, e);
    } on ArgTypeError catch (e) {
      response = StructuredResponse.error(
        summary: '${definition.name}: $e',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: ['pass ${e.key} as ${e.expected}'],
      );
    } catch (e, st) {
      response = looksLikeConnectionLoss(e)
          ? await _connectionLostResponse(session, e)
          : StructuredResponse.error(
              summary: '${definition.name} failed',
              errorKind: GlintErrorKind.internal,
              detail: '$e\n$st',
            );
    }
    response = await _checkDeviceGone(session, app, response);
    response = explainMissingBridge(response);
    response = _explainBreakpointPause(session, response);
    response = _warnSharedDevice(app, response);
    response = _warnLifecycleChecks(app, response);
    response = _warnSlept(start, response);
    logCall(session, request, response, start, app: app, call: call);
    return response.toCallResult();
  }

  /// Says so when the machine slept during the call, since the wall-clock time is then not the call's own.
  static StructuredResponse _warnSlept(DateTime start, StructuredResponse response) {
    final slept = CallProgress.current?.sleptSince(start) ?? 0;
    if (slept < 3000) return response;
    return response.addWarnings([
      'the machine slept for about ${(slept / 1000).round()}s during this call; the call itself did not take that long'
    ]);
  }

  /// Tells the agent once when the lifecycle checks keep failing for no visible reason, since the scene mode may be stale.
  static StructuredResponse _warnLifecycleChecks(AppSession? app, StructuredResponse response) {
    final warning = app?.takeLifecycleWarning();
    return warning == null ? response : response.addWarnings([warning]);
  }

  /// A no-change action on a device another live glint process drove recently: say so, since its input may be what the app received.
  static StructuredResponse _warnSharedDevice(AppSession? app, StructuredResponse response) {
    final id = app?.device.id;
    if (id == null || response.isError || response.data?['changed'] != false) return response;
    final other = DeviceClaims().heldByOther(id);
    if (other == null || other.idle) return response;
    return response.addWarnings([
      'another glint process (pid ${other.pid}${other.app == null ? '' : ', app ${other.app}'}) is also driving '
          'this device; input may interleave or not reach your app',
    ]);
  }

  /// The isolate stopped answering: name the likeliest cause, checking the lock screen first.
  Future<StructuredResponse> _unresponsiveResponse(GlintSession session, RuntimeUnresponsiveError e) async {
    if (pausedAtBreakpoint(session, e) case final paused?) return paused;
    bool? locked;
    try {
      locked = await session.backend.lockState();
    } on Object {
      locked = null;
    }
    final app = session.active;
    if (locked != true && app != null && app.hasDrawnFrame && app.sceneMode == SceneMode.flutter) {
      return StructuredResponse.appBusy(e.timeout);
    }
    return StructuredResponse.error(
      summary: locked == true
          ? 'the device is locked, so the app is suspended and runs no Dart code'
          : 'the app stopped answering: suspended in the background, paused at a '
              'breakpoint, or frozen',
      errorKind: GlintErrorKind.appUnresponsive,
      detail: e.toString(),
      nextSteps: [
        if (locked == true)
          'hardware_button unlock, then retry'
        else ...const [
          '`device op:screenshot` to see what the device shows',
          'if the app is in the background, `hardware_button home` and reopen it; '
              'if a debugger paused it, resume it',
          'attach again if the app was restarted',
        ],
      ],
    );
  }

  /// The session is attached, but in device mode: say what the tool is missing and what works without a Flutter tree.
  static StructuredResponse flutterModeRequiredResponse(String tool, AppSession app, SessionNotAttachedError cause) {
    return StructuredResponse.error(
      summary: '`$tool` needs a Flutter app; this session is in device mode '
          'on ${app.deviceName ?? app.id}',
      errorKind: GlintErrorKind.flutterModeRequired,
      detail: 'device mode drives the simulator with no Flutter widget tree, '
          'so the ${cause.missing} is unavailable',
      nextSteps: [
        'once the app is running, attach without mode:"device" '
            '(attach app:"<name>" or attach vmUri:<uri>)',
        if (app.device case IosSimulator(runner: null))
          'attach mode:"device" to read and tap system alerts and native screens by text',
        'in device mode use tap / long_press / swipe / drag with x,y '
            '(screenshot pixels), type, hardware_button, device op:screenshot',
      ],
    );
  }

  /// The VM connection is gone: says whether the app crashed (with the native crash) or was restarted or closed.
  Future<StructuredResponse> _connectionLostResponse(GlintSession session, Object e) async {
    final crash = await _recentCrash(session);
    return StructuredResponse.error(
      summary: crash == null
          ? 'VM service connection lost: the app may have hot-restarted or been terminated'
          : 'the app crashed: ${crash.line}',
      errorKind: GlintErrorKind.connectionLost,
      detail: crash == null
          ? e.toString()
          : [crash.reason, ...crash.frames.map((f) => '  at $f'), if (crash.source != null) 'report: ${crash.source}']
              .join('\n'),
      nextSteps: [
        if (crash != null) 'this is a crash in the app, worth reporting to the user with the frames above',
        'relaunch the app, then `attach` again',
      ],
    );
  }

  /// An action that failed because a breakpoint paused the app mid-call most likely landed: say so instead of "not delivered".
  StructuredResponse _explainBreakpointPause(GlintSession session, StructuredResponse response) {
    if (!response.isError || definition.name == 'breakpoint' || !_looksLikeStall(response)) return response;
    final hit = session.active?.breakpoints.pausedFor;
    if (hit == null || response.summary.contains('paused at breakpoint')) return response;
    return StructuredResponse.error(
      summary:
          '${response.summary}: the app paused at breakpoint ${hit.breakpoint.id} (hit ${hit.number}) during the call, '
          'so it most likely landed: ${hit.matchedLine}',
      errorKind: GlintErrorKind.appUnresponsive,
      detail: response.summary,
      nextSteps: const ['breakpoint op:status for the hit, then breakpoint op:resume'],
    );
  }

  /// Whether an error is the kind a paused app causes: unresponsive, never ready, or a timeout.
  static bool _looksLikeStall(StructuredResponse response) {
    final data = response.data ?? const <String, Object?>{};
    final kind = data['errorKind'];
    if (kind == GlintErrorKind.appUnresponsive.name ||
        kind == GlintErrorKind.appBusy.name ||
        kind == GlintErrorKind.targetNeverReady.name) {
      return true;
    }
    final text = '${response.summary} ${data['detail'] ?? ''}'.toLowerCase();
    return text.contains('timed out') || text.contains('timeout');
  }

  /// A read failed because glint itself paused the app at a log breakpoint; null otherwise.
  static StructuredResponse? pausedAtBreakpoint(GlintSession session, Object e) {
    final hit = session.active?.breakpoints.pausedFor;
    if (hit == null) return null;
    return StructuredResponse.error(
      summary: 'the app is paused at breakpoint ${hit.breakpoint.id} (hit ${hit.number}): ${hit.matchedLine}',
      errorKind: GlintErrorKind.appUnresponsive,
      detail: e.toString(),
      nextSteps: const ['breakpoint op:resume, then retry'],
    );
  }

  /// The widget tree came back empty: a system surface over an app that is not resumed, or no first frame yet.
  Future<StructuredResponse> noFrameResponse(GlintSession session, InspectorReadError e) async {
    if (pausedAtBreakpoint(session, e) case final paused?) return paused;
    final busy = appBusyCause(e);
    if (busy != null && (session.active?.hasDrawnFrame ?? false)) return StructuredResponse.appBusy(busy.timeout);
    String? lifecycle;
    try {
      lifecycle = await session.lifecycleState();
    } on Object {
      lifecycle = null;
    }
    await session.active?.refreshSceneMode();
    final covered = lifecycle != null && lifecycle != 'resumed';
    return StructuredResponse.error(
      summary: covered
          ? 'the app is "$lifecycle", not resumed, so there is no Flutter frame to read: '
              'a system dialog or another app is in front'
          : 'the app has no widget tree yet: it has not drawn its first frame '
              '(still starting, or waiting on something before runApp)',
      errorKind: GlintErrorKind.appNotResumed,
      detail: e.toString(),
      nextSteps: covered
          ? const [
              'call get_scene to read what is in front, then tap its buttons by text or glintId',
              'or `hardware_button home` and reopen the app',
            ]
          : const [
              'call get_scene to check for a system dialog in front, and answer it',
              'otherwise give the app a moment to start, then retry',
            ],
    );
  }

  /// The app's newest native crash from the last minute, if the VM dropped because it crashed.
  Future<NativeCrash?> _recentCrash(GlintSession session) async {
    try {
      final crashes = await session.active?.nativeCrashes() ?? const [];
      final newest = crashes.firstOrNull;
      if (newest == null || DateTime.now().difference(newest.time) > const Duration(minutes: 1)) return null;
      return newest;
    } on Object {
      return null;
    }
  }

  /// A gesture that failed because the glint-iossim binary is not built: say how to build it.
  static StructuredResponse explainMissingBridge(StructuredResponse response) {
    final detail = response.data?['detail'];
    if (!response.isError ||
        detail is! String ||
        !detail.contains('glint-iossim') ||
        !detail.contains('No such file')) {
      return response;
    }
    return response.copyWith(
      summary: '${response.summary}: the glint-iossim bridge is not built',
      nextSteps: [
        'build it: cd <glint>/native/ios_sim_bridge && swift build -c release',
        'or point $bridgePathEnv at a glint-iossim binary and attach again',
      ],
    );
  }

  static const _deviceSensitive = {
    GlintErrorKind.connectionLost,
    GlintErrorKind.backendToolError,
    GlintErrorKind.internal,
  };

  /// A lost VM or a failing native tool is often a simulator that was closed.
  /// Ask the host once; when the device is gone, say so and drop its session.
  Future<StructuredResponse> _checkDeviceGone(
      GlintSession session, AppSession? app, StructuredResponse response) async {
    if (!response.isError || app == null) return response;
    final kind = enumByName(GlintErrorKind.values, response.data?['errorKind'] as String?);
    if (kind == null || !_deviceSensitive.contains(kind)) return response;
    final adb = app.device is AndroidDevice ? (app.device as AndroidDevice).adbPath : 'adb';
    final bool present;
    try {
      present = await DeviceDiscovery(adbPath: adb).isDevicePresent(app.id, app.platform);
    } on Object {
      return response;
    }
    if (present) return response;
    await session.detach(deviceId: app.id);
    return deviceGoneResponse(session, app);
  }

  /// The device behind [app] is gone (a closed simulator or emulator, or an unplugged phone): name it, and say how back.
  static StructuredResponse deviceGoneResponse(GlintSession session, AppSession app) {
    final what = app.platform == DevicePlatform.ios ? 'simulator' : 'emulator';
    final remaining = session.apps;
    if (app.platform == DevicePlatform.android && !app.id.startsWith('emulator-')) {
      return StructuredResponse.error(
        summary: 'phone ${app.deviceName ?? app.id} disconnected: adb no '
            'longer lists it, so ${app.label} is gone',
        errorKind: GlintErrorKind.deviceGone,
        detail: 'device ${app.id} is missing from `adb devices`; its session '
            'was dropped from the pool',
        nextSteps: [
          'ask the user to reconnect the phone (USB cable or wireless debugging), '
              'then attach device:"${app.id}"',
          if (remaining.isNotEmpty)
            'or continue on: ${remaining.map((a) => '"${a.label}"').join(", ")} (attach app:"<name>")',
        ],
      );
    }
    return StructuredResponse.error(
      summary: '$what ${app.deviceName ?? app.id} is no longer booted — it was '
          'closed or crashed, so ${app.label} is gone',
      errorKind: GlintErrorKind.deviceGone,
      detail: 'device ${app.id} is not in the booted list; its session was '
          'dropped from the pool',
      nextSteps: [
        'attach device:"${app.id}" boots it and relaunches ${app.label} from history',
        if (remaining.isNotEmpty)
          'or continue on: ${remaining.map((a) => '"${a.label}"').join(", ")} (attach app:"<name>")',
        'ask the user if the $what should stay open while you work',
      ],
    );
  }

  /// Records one call in the action log + usage recorder. Public so a
  /// composite tool (batch) can log each step under its own tool name.
  void logCall(
    GlintSession session,
    CallToolRequest request,
    StructuredResponse response,
    DateTime start, {
    AppSession? app,
    ExploreCall? call,
  }) {
    if (CallProgress.current?.abandoned ?? false) return;
    final slept = CallProgress.current?.sleptSince(start) ?? 0;
    final elapsedMs = DateTime.now().difference(start).inMilliseconds - slept;
    if (call != null) session.explore.completeCall(app, call, definition.name, request.arguments, response);
    final seq = session.actionLog.allocateSequence();
    final argKeys = UsageRecorder.argKeysFrom(request.arguments);
    final resultBytes = _resultBytes(response);
    if (!response.isError) {
      session.actionLog.record(SuccessEntry(
        sequence: seq,
        timestamp: start,
        tool: definition.name,
        elapsedMs: elapsedMs,
        summary: _shortSummary(response.summary),
        args: _scrubArgs(request.arguments),
        armed: response.data?['armed'] as Map<String, Object?>?,
      ));
      session.usage.record(
        tool: definition.name,
        outcome: UsageRecorder.outcomeFrom(
          isError: false,
          structured: response.data,
        ),
        argKeys: argKeys,
        durationMs: elapsedMs,
        resultBytes: resultBytes,
      );
      return;
    }
    final kindName = response.data?['errorKind'] as String?;
    final errorKind = enumByName(GlintErrorKind.values, kindName) ?? GlintErrorKind.internal;
    session.actionLog.record(FailureEntry(
      sequence: seq,
      timestamp: start,
      tool: definition.name,
      elapsedMs: elapsedMs,
      summary: _shortSummary(response.summary),
      errorKind: errorKind,
      detail: response.data?['detail'] as String?,
      args: _scrubArgs(request.arguments),
    ));
    session.usage.record(
      tool: definition.name,
      outcome: ToolOutcome.error,
      argKeys: argKeys,
      durationMs: elapsedMs,
      resultBytes: resultBytes,
      errorKind: errorKind.name,
    );
  }

  /// `app:` named none or several attached apps: list what is attached.
  static StructuredResponse unknownAppResponse(GlintSession session, String target, List<AppSession> matches) {
    final pooled = session.apps;
    return StructuredResponse.error(
      summary: matches.isEmpty
          ? 'no attached app matches app:"$target"'
          : 'app:"$target" is ambiguous — ${matches.length} attached apps match',
      errorKind: GlintErrorKind.unknownApp,
      detail: pooled.isEmpty
          ? 'nothing is attached'
          : 'attached: ${pooled.map((a) => "${a.label} on ${a.deviceName ?? a.id}").join(", ")}',
      nextSteps: [
        if (pooled.isEmpty) 'call `attach` first',
        for (final a in (matches.isEmpty ? pooled : matches)) 'app:"${a.deviceName ?? a.id}" or app:"${a.label}"',
        'or `attach` (no args) to discover a running app that is not attached yet',
      ],
    );
  }

  int _resultBytes(StructuredResponse r) => r.wireBytes;

  String _shortSummary(String s) {
    const max = 160;
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }

  /// Drops the VM URI and keeps only the length of typed text, so the action log never holds what the agent typed.
  Map<String, Object?>? _scrubArgs(Map<String, Object?>? args) {
    if (args == null) return null;
    return {
      for (final e in args.entries)
        if (e.key != 'vmUri')
          e.key: definition.name == 'type' && e.key == 'text' && e.value is String
              ? '<${(e.value as String).length} chars>'
              : e.value,
    };
  }
}

/// The time a call may run before glint cancels it, unless its tool raises the ceiling for a wait the agent asked for.
const Duration kDefaultCallCeiling = Duration(seconds: 60);

/// The P4 v0 default tool set. Pass a different list to
/// [GlintMcpServer.fromStreamChannel] to plug in custom tools while
/// keeping the same envelope + session contract.
const List<GlintTool> kDefaultGlintTools = [
  AttachTool(),
  DeviceTool(),
  KillAppTool(),
  HotReloadTool(),
  MediaTool(),
  LocationTool(),
  MapTool(),
  ShutdownSimTool(),
  GetSceneTool(),
  ExploreTool(),
  ResolveTool(),
  TapTool(),
  LongPressTool(),
  PinchTool(),
  SwipeTool(),
  DragTool(),
  ScrollTool(),
  ScrollToFindTool(),
  TypeTool(),
  KeyTool(),
  HardwareButtonTool(),
  WaitForSettleTool(),
  WaitForTool(),
  WatchTool(),
  NotificationsTool(),
  SensorsTool(),
  BatchTool(),
  RecordTool(),
  LogsTool(),
  AppLogsTool(),
  BreakpointTool(),
  SessionTool(),
  ConfigTool(),
  ReportIssueTool(),
  TelemetryTool(),
];

/// A read that failed because the VM service went away, whatever wrapper it arrived in.
bool looksLikeConnectionLoss(Object e) {
  final m = e.toString();
  return e is RuntimeConnectionLostError ||
      m.contains('RuntimeConnectionLostError') ||
      m.contains('Service has disappeared') ||
      m.contains('Service connection disposed') ||
      m.contains('VM service is not connected');
}
