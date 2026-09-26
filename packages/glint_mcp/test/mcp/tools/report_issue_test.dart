import 'package:glint_mcp/src/mcp/tools/report_issue_tool.dart';
import 'package:test/test.dart';

void main() {
  group('labelsForType', () {
    test('bug → [glint, bug, agent-filed]', () {
      expect(labelsForType('bug'), ['glint', 'bug', 'agent-filed']);
    });

    test('ux → [glint, ux-friction, agent-filed]', () {
      expect(labelsForType('ux'), ['glint', 'ux-friction', 'agent-filed']);
    });

    test('feature → [glint, enhancement, agent-filed]', () {
      expect(labelsForType('feature'), ['glint', 'enhancement', 'agent-filed']);
    });

    test('unknown type → [glint, agent-filed]', () {
      expect(labelsForType('weird'), ['glint', 'agent-filed']);
    });
  });
}
