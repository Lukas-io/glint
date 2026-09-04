import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import '../../observability.dart';
import '../../runtime.dart';
import 'envelope.dart';
import 'session.dart';
import 'tool_args.dart';
import 'tools/app_logs_tool.dart';
import 'tools/attach_tool.dart';
import 'tools/batch_tool.dart';
import 'tools/config_tool.dart';
import 'tools/device_tool.dart';
import 'tools/drag_tool.dart';
import 'tools/get_scene_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/kill_app_tool.dart';
import 'tools/logs_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/report_issue_tool.dart';
import 'tools/resolve_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/session_tool.dart';
import 'tools/shutdown_sim_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/telemetry_tool.dart';
import 'tools/type_tool.dart';
import 'tools/wait_for_settle_tool.dart';

/// One MCP tool. Subclasses provide a [definition] + [handle]; [invoke]
/// wraps both with the envelope conversion + uniform error catch.
abstract class GlintTool {
  const GlintTool();

  Tool get definition;

  /// [definition] plus the shared `app` routing arg — what the server registers.
  Tool get registeredDefinition =>
      routesByApp ? withAppArg(definition) : definition;

  /// Tools that give `app` their own meaning (attach) opt out of routing.
  bool get routesByApp => true;

  /// Adds the optional `app` property every routed tool accepts.
  static Tool withAppArg(Tool tool) {
    final raw = tool as Map<String, Object?>;
    final schema = Map<String, Object?>.from(
        raw['inputSchema'] as Map<String, Object?>? ?? const {});
    final props = Map<String, Object?>.from(
        (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {});
    props['app'] = Schema.string(
      description: 'Which attached app to target when several are attached: '
          'device id, app name, package, or simulator name. Defaults to the '
          'active app.',
    );
    return Tool.fromMap({
      ...raw,
      'inputSchema': {...schema, 'type': 'object', 'properties': props},
    });
  }

  FutureOr<StructuredResponse> handle(
    GlintSession session,
    CallToolRequest request,
  );

  /// Error-bubbling contract:
  ///   - [SessionNotAttachedError] → structured `sessionNotAttached` envelope.
  ///   - Any other throw from [handle] (including [RPCError] from a dropped
  ///     VM connection) → structured `internal` envelope with the detail.
  /// Nothing escapes; the wire-level RPC error is reserved for true
  /// protocol failures (unknown tool, server doesn't support tools, etc.)
  /// and is handled by dart_mcp's [ToolsSupport.callTool].
  Future<CallToolResult> invoke(
    GlintSession session,
    CallToolRequest request,
  ) async {
    final start = DateTime.now();
    StructuredResponse response;
    final target =
        routesByApp ? (request.arguments?['app'] as String?) : null;
    var app = session.active;
    try {
      if (target == null) {
        response = await handle(session, request);
      } else {
        final matches = session.matchApps(target);
        if (matches.length != 1) {
          response = unknownAppResponse(session, target, matches);
        } else {
          app = matches.single;
          response = await session.withApp(
              matches.single, () async => await handle(session, request));
        }
      }
    } on SessionNotAttachedError catch (e) {
      final pooled = session.apps;
      response = StructuredResponse.error(
        summary: pooled.isEmpty
            ? 'glint is not attached to a Flutter app yet'
            : 'no active app — ${pooled.length} attached app(s) to pick from',
        errorKind: GlintErrorKind.sessionNotAttached,
        detail: e.toString(),
        nextSteps: pooled.isEmpty
            ? const ['call `attach` (no args) to discover and connect the running app']
            : [
                for (final a in pooled)
                  'attach app:"${a.label}"  (${a.deviceName ?? a.id})',
              ],
      );
    } on RuntimeConnectionLostError catch (e) {
      response = StructuredResponse.error(
        summary: 'VM service connection lost — the app may have hot-restarted '
            'or been terminated',
        errorKind: GlintErrorKind.connectionLost,
        detail: e.toString(),
        nextSteps: const [
          'call `attach` again with the same vmUri to reconnect',
        ],
      );
    } on RuntimeUnresponsiveError catch (e) {
      response = await _unresponsiveResponse(session, e);
    } catch (e, st) {
      response = StructuredResponse.error(
        summary: '${definition.name} failed',
        errorKind: GlintErrorKind.internal,
        detail: '$e\n$st',
      );
    }
    response = await _checkDeviceGone(session, app, response);
    logCall(session, request, response, start);
    return response.toCallResult();
  }

  /// The isolate stopped answering: name the likeliest cause, checking the lock screen first.
  Future<StructuredResponse> _unresponsiveResponse(
      GlintSession session, RuntimeUnresponsiveError e) async {
    bool? locked;
    try {
      locked = await session.backend.lockState();
    } on Object {
      locked = null;
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
    final kind = enumByName(
        GlintErrorKind.values, response.data?['errorKind'] as String?);
    if (kind == null || !_deviceSensitive.contains(kind)) return response;
    final adb = app.device is AndroidDevice
        ? (app.device as AndroidDevice).adbPath
        : 'adb';
    final bool present;
    try {
      present = await DeviceDiscovery(adbPath: adb)
          .isDevicePresent(app.id, app.platform);
    } on Object {
      return response;
    }
    if (present) return response;
    await session.detach(deviceId: app.id);
    return deviceGoneResponse(session, app);
  }

  /// The device behind [app] is no longer booted: name it, and say how back.
  static StructuredResponse deviceGoneResponse(
      GlintSession session, AppSession app) {
    final what = app.platform == DevicePlatform.ios ? 'simulator' : 'emulator';
    final remaining = session.apps;
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
    DateTime start,
  ) {
    final elapsedMs = DateTime.now().difference(start).inMilliseconds;
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
    final errorKind =
        enumByName(GlintErrorKind.values, kindName) ?? GlintErrorKind.internal;
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
  static StructuredResponse unknownAppResponse(
      GlintSession session, String target, List<AppSession> matches) {
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
        for (final a in (matches.isEmpty ? pooled : matches))
          'app:"${a.deviceName ?? a.id}" or app:"${a.label}"',
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

  Map<String, Object?>? _scrubArgs(Map<String, Object?>? args) {
    if (args == null) return null;
    // Drop the vmUri — long and sensitive-ish.
    return {for (final e in args.entries) if (e.key != 'vmUri') e.key: e.value};
  }
}

/// The P4 v0 default tool set. Pass a different list to
/// [GlintMcpServer.fromStreamChannel] to plug in custom tools while
/// keeping the same envelope + session contract.
const List<GlintTool> kDefaultGlintTools = [
  AttachTool(),
  DeviceTool(),
  KillAppTool(),
  ShutdownSimTool(),
  GetSceneTool(),
  ResolveTool(),
  TapTool(),
  LongPressTool(),
  SwipeTool(),
  DragTool(),
  ScrollTool(),
  ScrollToFindTool(),
  TypeTool(),
  HardwareButtonTool(),
  WaitForSettleTool(),
  BatchTool(),
  LogsTool(),
  AppLogsTool(),
  SessionTool(),
  ConfigTool(),
  ReportIssueTool(),
  TelemetryTool(),
];
