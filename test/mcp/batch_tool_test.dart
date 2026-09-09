import 'package:dart_mcp/server.dart';
import 'package:glint/glint.dart';
import 'package:test/test.dart';

Map<String, Object?> _structured(CallToolResult r) =>
    r.structuredContent as Map<String, Object?>;

void main() {
  final session = GlintSession();
  const tool = BatchTool();

  group('batch validation', () {
    test('empty steps → invalidArgument', () async {
      final r = await tool.invoke(
          session, CallToolRequest(name: 'batch', arguments: const {'steps': []}));
      expect(_structured(r)['errorKind'], 'invalidArgument');
    });

    test('unknown step tool → invalidArgument naming the step', () async {
      final r = await tool.invoke(
        session,
        CallToolRequest(name: 'batch', arguments: const {
          'steps': [
            {'tool': 'attach', 'args': {}},
          ],
        }),
      );
      final s = _structured(r);
      expect(s['errorKind'], 'invalidArgument');
      expect(s['summary'], contains('step 1'));
    });

    test('a valid step on an unattached session → sessionNotAttached',
        () async {
      final r = await tool.invoke(
        session,
        CallToolRequest(name: 'batch', arguments: const {
          'steps': [
            {'tool': 'tap', 'args': {'glintId': 'x'}},
          ],
        }),
      );
      expect(_structured(r)['errorKind'], 'sessionNotAttached');
    });

    test('is registered with the app routing arg', () {
      final def = tool.registeredDefinition as Map<String, Object?>;
      final props = (def['inputSchema'] as Map)['properties'] as Map;
      expect(props.containsKey('steps'), isTrue);
      expect(props.containsKey('app'), isTrue);
      expect(kDefaultGlintTools.whereType<BatchTool>(), isNotEmpty);
    });
  });
}
