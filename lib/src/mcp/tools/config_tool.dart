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
              description: 'Config key to set, e.g. scrollMaxScrolls '
                  '(required for set; `get` lists all keys + current values).',
            ),
            'value': Schema.combined(
              description: 'New value for `key` (required for set). Type matches '
                  'the key: int (scrollMaxScrolls), double (scrollAmountFraction), '
                  'or bool.',
            ),
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
        final keys = cfg.toJson().keys.join(', ');
        if (key == null || value == null) {
          return StructuredResponse.error(
            summary: 'op=set requires both `key` and `value`',
            errorKind: GlintErrorKind.invalidArgument,
            nextSteps: ['keys: $keys'],
          );
        }
        final err = cfg.set(key, value);
        if (err != null) {
          return StructuredResponse.error(
            summary: err,
            errorKind: GlintErrorKind.invalidArgument,
            nextSteps: ['keys: $keys'],
          );
        }
        // Echo only the changed setting — `config op:get` returns the full map.
        return StructuredResponse(
          summary: '$key = $value',
          data: {'key': key, 'value': value},
        );
      default:
        return StructuredResponse.error(
          summary: 'unknown op: $op (use get | set)',
          errorKind: GlintErrorKind.invalidArgument,
        );
    }
  }
}
