import 'package:dart_mcp/server.dart';
import 'package:glint/observability.dart';
import 'package:glint/interaction.dart' show GlintErrorKind;
import 'package:glint/src/mcp/envelope.dart';
import 'package:glint/src/mcp/tool.dart';
import 'package:glint/src/mcp/tool_args.dart';
import 'package:test/test.dart';

void main() {
  group('argInt', () {
    test('reads ints, whole doubles and numeric strings', () {
      final args = <String, Object?>{'a': 15000, 'b': 15000.0, 'c': '15000', 'd': ' 7 '};
      expect([for (final k in ['a', 'b', 'c', 'd']) argInt(args, k)],
          [15000, 15000, 15000, 7]);
    });

    test('absent is null; a fraction or text is an ArgTypeError naming the key', () {
      expect(argInt(const {}, 'x'), isNull);
      expect(() => argInt({'x': 1.5}, 'x'), throwsA(isA<ArgTypeError>()));
      expect(
          () => argInt({'x': 'soon'}, 'x'),
          throwsA(isA<ArgTypeError>().having(
              (e) => e.toString(), 'text', 'x must be a whole number, got "soon"')));
    });
  });

  test('argNum and argBool accept their string forms', () {
    expect(argNum({'f': '0.5'}, 'f'), 0.5);
    expect(argBool({'b': 'true'}, 'b'), isTrue);
    expect(argBool({'b': false}, 'b'), isFalse);
    expect(() => argBool({'b': 'yes'}, 'b'), throwsA(isA<ArgTypeError>()));
  });

  group('GlintConfig.set', () {
    test('accepts 15000, 15000.0 and "15000" for an int key', () {
      for (final v in <Object>[15000, 15000.0, '15000']) {
        final cfg = GlintConfig();
        expect(cfg.set('attachProbeTimeoutMs', v), isNull, reason: '$v');
        expect(cfg.attachProbeTimeoutMs, 15000);
      }
    });

    test('still refuses zero, negatives and fractions', () {
      for (final v in <Object>[0, -5, 1.5, 'abc']) {
        expect(GlintConfig().set('attachProbeTimeoutMs', v), isNotNull, reason: '$v');
      }
    });
  });

  group('checkArguments', () {
    final tool = Tool(
      name: 't',
      inputSchema: ObjectSchema(
        properties: {'n': Schema.int(), 'on': Schema.bool(), 's': Schema.string()},
        required: ['s'],
      ),
    );
    CallToolRequest req(Map<String, Object?> a) =>
        CallToolRequest(name: 't', arguments: {...a});

    test('numeric and bool strings are coerced in place', () {
      final r = req({'n': '300', 'on': 'true', 's': 'x'});
      expect(GlintTool.checkArguments(tool, r), isNull);
      expect(r.arguments, {'n': 300, 'on': true, 's': 'x'});
    });

    test('a wrong type or a missing required field is invalidArgument', () {
      for (final a in [
        {'n': 'soon', 's': 'x'},
        {'n': 1},
      ]) {
        final res = GlintTool.checkArguments(tool, req(a));
        expect(res?.data?['errorKind'], 'invalidArgument', reason: '$a');
        expect(res?.nextSteps.single, contains('n, on, s'));
      }
    });
  });

  test('a missing glint-iossim binary gets build next steps', () {
    final r = GlintTool.explainMissingBridge(StructuredResponse.error(
      summary: 'swiped failed at (1,2)->(3,4)',
      errorKind: GlintErrorKind.backendToolError,
      detail: 'ProcessException: No such file or directory\n  Command: '
          'native/ios_sim_bridge/.build/debug/glint-iossim swipe',
    ));
    expect(r.summary, endsWith('the glint-iossim bridge is not built'));
    expect(r.nextSteps.first, contains('swift build'));
  });

  group('unknown arguments', () {
    final tool = Tool(
      name: 'scroll_to_find',
      inputSchema: ObjectSchema(properties: {
        'targetGlintId': Schema.string(),
        'direction': Schema.string(),
      }),
    );

    test('are refused with the likely intended name', () {
      final r = GlintTool.checkArguments(tool,
          CallToolRequest(name: 'scroll_to_find', arguments: {'glintId': 'x'}));
      expect(r?.summary, 'scroll_to_find: unknown argument glintId');
      expect(r?.nextSteps.first, 'use targetGlintId instead of glintId');
    });

    test('closestArgName tries containment, then edit distance', () {
      expect(GlintTool.closestArgName('glintId', ['targetGlintId']), 'targetGlintId');
      expect(GlintTool.closestArgName('direciton', ['direction']), 'direction');
      expect(GlintTool.closestArgName('zzz', ['direction']), isNull);
    });
  });
}
