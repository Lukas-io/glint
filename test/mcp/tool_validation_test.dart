// Per-tool input-validation tests. We run each tool's `invoke` with an
// argument it should reject, against a bare (un-attached) GlintSession,
// and verify the envelope shape. No live VM required.

import 'package:dart_mcp/server.dart';
import 'package:glint/glint.dart';
import 'package:test/test.dart';

Map<String, Object?> _structured(dynamic callResult) {
  return (callResult as CallToolResult).structuredContent
      as Map<String, Object?>;
}

void main() {
  final session = GlintSession();

  group('attach', () {
    test('unknown platform → invalidArgument', () async {
      const tool = AttachTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'attach', arguments: const {
          'vmUri': 'ws://0:0/ws',
          'platform': 'symbian',
          'device': 'x',
        }),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });
  });

  group('hardware_button', () {
    test('unknown button → invalidArgument', () async {
      const tool = HardwareButtonTool();
      // session not attached, but invalidArgument is checked BEFORE
      // session access, so it fires first.
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'hardware_button', arguments: const {
          'button': 'fingerprint',
        }),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });
  });

  group('scroll', () {
    test('unknown direction → invalidArgument', () async {
      const tool = ScrollTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'scroll', arguments: const {
          'direction': 'sideways',
        }),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });
  });

  group('scroll_to_find', () {
    test('unknown direction → invalidArgument', () async {
      const tool = ScrollToFindTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'scroll_to_find', arguments: const {
          'targetGlintId': 'x',
          'direction': 'inward',
        }),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });

    test('neither targetGlintId nor targetTextContent → invalidArgument',
        () async {
      const tool = ScrollToFindTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'scroll_to_find', arguments: const {}),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });

    test('both targetGlintId AND targetTextContent → invalidArgument',
        () async {
      const tool = ScrollToFindTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'scroll_to_find', arguments: const {
          'targetGlintId': 'x',
          'targetTextContent': 'y',
        }),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'invalidArgument');
    });
  });

  group('tap (unattached session)', () {
    test('falls through to sessionNotAttached envelope', () async {
      const tool = TapTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'tap', arguments: const {'glintId': 'fab'}),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'sessionNotAttached');
    });
  });

  group('get_scene (unattached session)', () {
    test('text format default falls through to sessionNotAttached', () async {
      const tool = GetSceneTool();
      final result = await tool.invoke(
        session,
        CallToolRequest(name: 'get_scene', arguments: const {}),
      );
      final s = _structured(result);
      expect(s['errorKind'], 'sessionNotAttached');
    });
  });
}
