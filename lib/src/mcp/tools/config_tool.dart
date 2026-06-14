import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Get / set runtime defaults — poll cadences, ceilings, scroll size.
/// Ops: `get` (full snapshot) or `set` (one key/value).
class ConfigTool extends GlintTool {
  const ConfigTool();

  @override
  Tool get definition => Tool(
        name: 'config',
        description: 'Inspect or override glint defaults at runtime '
            '(readyTimeoutMs, settleCeilingMs, scrollMaxScrolls, '
            'scrollAmountFraction, etc.). Per-call args still win over config.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'get | set'),
            'key': Schema.string(
              description: 'Config key (required for set).',
            ),
            'value': Schema.combined(),
          },
          required: ['op'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = args['op']! as String;
    final cfg = session.config;

    switch (op) {
      case 'get':
        return StructuredResponse(
          summary: cfg
              .toJson()
              .entries
              .map((e) => '${e.key} = ${e.value}')
              .join('\n'),
          data: {'config': cfg.toJson()},
        );
      case 'set':
        final key = args['key'] as String?;
        final value = args['value'];
        if (key == null || value == null) {
          return StructuredResponse.error(
            summary: 'op=set requires both `key` and `value`',
            errorKind: GlintErrorKind.invalidArgument,
          );
        }
        final err = cfg.set(key, value);
        if (err != null) {
          return StructuredResponse.error(
            summary: err,
            errorKind: GlintErrorKind.invalidArgument,
          );
        }
        return StructuredResponse(
          summary: '$key = $value',
          data: {'config': cfg.toJson()},
        );
      default:
        return StructuredResponse.error(
          summary: 'unknown op: $op (use get | set)',
          errorKind: GlintErrorKind.invalidArgument,
        );
    }
  }
}
