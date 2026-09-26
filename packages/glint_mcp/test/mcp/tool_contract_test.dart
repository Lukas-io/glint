import 'dart:convert';
import 'dart:io';

import 'package:glint_mcp/glint.dart';
import 'package:test/test.dart';

/// Tool names and input schemas are glint's public API; run with GLINT_UPDATE_GOLDENS=1 to accept a deliberate change.
void main() {
  test('tool names and input schemas match the committed contract', () {
    final contract = {
      for (final t in kDefaultGlintTools)
        t.definition.name: jsonDecode(jsonEncode(t.definition.inputSchema)),
    };
    final encoded = '${const JsonEncoder.withIndent('  ').convert(contract)}\n';
    final golden = File('test/goldens/tool_contract.json');
    if (Platform.environment['GLINT_UPDATE_GOLDENS'] == '1' || !golden.existsSync()) {
      golden.writeAsStringSync(encoded);
    }
    expect(encoded, golden.readAsStringSync(),
        reason: 'A tool name or input schema changed. If intended, rerun with '
            'GLINT_UPDATE_GOLDENS=1 and commit test/goldens/tool_contract.json.');
  });
}
