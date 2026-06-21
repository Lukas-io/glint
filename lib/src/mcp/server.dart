import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../instructions/glint_instructions.dart';
import 'session.dart';
import 'tool.dart';

/// The glint MCP server. Registers every tool in [kDefaultGlintTools]
/// against a single [GlintSession] held for the connection's lifetime.
base class GlintMcpServer extends MCPServer with ToolsSupport {
  GlintMcpServer.fromStreamChannel(
    super.channel, {
    GlintSession? session,
    List<GlintTool> tools = kDefaultGlintTools,
  })  : session = session ?? GlintSession(),
        _tools = tools,
        super.fromStreamChannel(
          implementation: Implementation(name: 'glint', version: _version),
          instructions: kGlintInstructions,
        ) {
    this.session.progressNotifier = notifyProgress;
  }

  static const _version = '0.0.1';

  final GlintSession session;
  final List<GlintTool> _tools;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    for (final tool in _tools) {
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

