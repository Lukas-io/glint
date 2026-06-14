/// Module D — MCP server. One barrel covering the server class, the
/// per-connection session, the response envelope, the tool base + registry,
/// and the concrete tool implementations.
library;

export 'src/mcp/armed.dart';
export 'src/mcp/envelope.dart';
export 'src/mcp/server.dart';
export 'src/mcp/session.dart';
export 'src/mcp/tool.dart';
export 'src/mcp/tools/app_logs_tool.dart';
export 'src/mcp/tools/attach_tool.dart';
export 'src/mcp/tools/config_tool.dart';
export 'src/mcp/tools/drag_tool.dart';
export 'src/mcp/tools/get_scene_tool.dart';
export 'src/mcp/tools/hardware_button_tool.dart';
export 'src/mcp/tools/logs_tool.dart';
export 'src/mcp/tools/long_press_tool.dart';
export 'src/mcp/tools/report_issue_tool.dart';
export 'src/mcp/tools/resolve_tool.dart';
export 'src/mcp/tools/scroll_to_find_tool.dart';
export 'src/mcp/tools/scroll_tool.dart';
export 'src/mcp/tools/session_tool.dart';
export 'src/mcp/tools/swipe_tool.dart';
export 'src/mcp/tools/tap_tool.dart';
export 'src/mcp/tools/type_tool.dart';
export 'src/mcp/tools/wait_for_settle_tool.dart';
