import 'dart:async';

import 'package:dart_mcp/server.dart';

import 'envelope.dart';
import 'session.dart';
import 'tools/attach_tool.dart';
import 'tools/get_scene_tool.dart';
import 'tools/hardware_button_tool.dart';
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
        errorKind: 'SessionNotAttached',
        detail: e.toString(),
        nextSteps: const [
          'call the `attach` tool first with the running app\'s VM URI and device target',
        ],
      ).toCallResult();
    } catch (e, st) {
      return StructuredResponse.error(
        summary: '${definition.name} failed',
        errorKind: e.runtimeType.toString(),
        detail: '$e\n$st',
      ).toCallResult();
    }
  }
}

class ToolRegistry {
  ToolRegistry(this.tools);

  factory ToolRegistry.defaults() => ToolRegistry(_kDefaults);

  final List<GlintTool> tools;
}

const List<GlintTool> _kDefaults = [
  AttachTool(),
  GetSceneTool(),
  TapTool(),
  SwipeTool(),
  TypeTool(),
  HardwareButtonTool(),
];
