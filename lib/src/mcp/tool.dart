import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import '../../observability.dart';
import 'envelope.dart';
import 'session.dart';
import 'tools/app_logs_tool.dart';
import 'tools/attach_tool.dart';
import 'tools/drag_tool.dart';
import 'tools/get_scene_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/logs_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/resolve_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/session_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/type_tool.dart';
import 'tools/wait_for_settle_tool.dart';

/// One MCP tool. Subclasses provide a [definition] + [handle]; [invoke]
/// wraps both with the envelope conversion + uniform error catch.
abstract class GlintTool {
  const GlintTool();

  Tool get definition;

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
    try {
      response = await handle(session, request);
    } on SessionNotAttachedError catch (e) {
      response = StructuredResponse.error(
        summary: 'glint is not attached to a Flutter app yet',
        errorKind: GlintErrorKind.sessionNotAttached,
        detail: e.toString(),
        nextSteps: const [
          'call the `attach` tool first with the running app\'s VM URI and device target',
        ],
      );
    } catch (e, st) {
      response = StructuredResponse.error(
        summary: '${definition.name} failed',
        errorKind: GlintErrorKind.internal,
        detail: '$e\n$st',
      );
    }
    _log(session, request, response, start);
    return response.toCallResult();
  }

  void _log(
    GlintSession session,
    CallToolRequest request,
    StructuredResponse response,
    DateTime start,
  ) {
    final elapsedMs = DateTime.now().difference(start).inMilliseconds;
    final seq = session.actionLog.allocateSequence();
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
      return;
    }
    final kindName = response.data?['errorKind'] as String?;
    final errorKind = GlintErrorKind.values
            .where((e) => e.name == kindName)
            .firstOrNull ??
        GlintErrorKind.internal;
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
  }

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
  LogsTool(),
  AppLogsTool(),
  SessionTool(),
];
