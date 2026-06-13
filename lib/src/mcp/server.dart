import 'dart:async';

import 'package:dart_mcp/server.dart';

import 'session.dart';
import 'tool.dart';

/// The glint MCP server. Registers every tool in [ToolRegistry] against
/// a single [GlintSession] held for the connection's lifetime.
base class GlintMcpServer extends MCPServer with ToolsSupport {
  GlintMcpServer.fromStreamChannel(
    super.channel, {
    GlintSession? session,
    ToolRegistry? registry,
  })  : session = session ?? GlintSession(),
        _registry = registry ?? ToolRegistry.defaults(),
        super.fromStreamChannel(
          implementation: Implementation(name: 'glint', version: _version),
          instructions: _instructions,
        );

  static const _version = '0.0.1';

  static const _instructions = '''
glint lets you drive a running Flutter app on a simulator or emulator.

Workflow:
  1. `attach` to a running Flutter app once — provide the VM service URI plus the device target.
  2. `get_scene` to read the current screen. Lines are addressable by their glintId; leading marker indicates affordance (`*` tappable, `>` typeable, `<>` scrollable).
  3. `tap` / `swipe` / `type` / `hardware_button` to drive the app.

Every tool response uses the same envelope: a short `summary`, optional `warnings` (non-fatal observations), and optional `nextSteps`. Failures carry an `errorKind` you can branch on (UnresolvedTarget, NotHittable, UnsupportedBackendAction, BackendToolError, GeometryResolveError, SessionNotAttached).
''';

  final GlintSession session;
  final ToolRegistry _registry;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    for (final tool in _registry.tools) {
      registerTool(
        tool.definition,
        (req) => tool.invoke(session, req),
      );
    }
    return result;
  }

  @override
  Future<void> shutdown() async {
    await session.detach();
    await super.shutdown();
  }
}

