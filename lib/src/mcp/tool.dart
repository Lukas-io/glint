import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../../interaction.dart';
import 'envelope.dart';
import 'session.dart';
import 'tools/attach_tool.dart';
import 'tools/drag_tool.dart';
import 'tools/get_scene_tool.dart';
import 'tools/hardware_button_tool.dart';
import 'tools/long_press_tool.dart';
import 'tools/resolve_tool.dart';
import 'tools/scroll_to_find_tool.dart';
import 'tools/scroll_tool.dart';
import 'tools/swipe_tool.dart';
import 'tools/tap_tool.dart';
import 'tools/type_tool.dart';

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
    try {
      final response = await handle(session, request);
      return response.toCallResult();
    } on SessionNotAttachedError catch (e) {
      return StructuredResponse.error(
        summary: 'glint is not attached to a Flutter app yet',
        errorKind: GlintErrorKind.sessionNotAttached,
        detail: e.toString(),
        nextSteps: const [
          'call the `attach` tool first with the running app\'s VM URI and device target',
        ],
      ).toCallResult();
    } catch (e, st) {
      return StructuredResponse.error(
        summary: '${definition.name} failed',
        errorKind: GlintErrorKind.internal,
        detail: '$e\n$st',
      ).toCallResult();
    }
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
];
