/// Module D — MCP server. One barrel covering the server class, the
/// per-connection session, the response envelope, the tool base + registry,
/// and the concrete tool implementations.
library;

export 'src/mcp/envelope.dart';
export 'src/mcp/server.dart';
export 'src/mcp/session.dart';
export 'src/mcp/tool.dart';
export 'src/mcp/tools/attach_tool.dart';
export 'src/mcp/tools/get_scene_tool.dart';
export 'src/mcp/tools/hardware_button_tool.dart';
export 'src/mcp/tools/swipe_tool.dart';
export 'src/mcp/tools/tap_tool.dart';
export 'src/mcp/tools/type_tool.dart';
