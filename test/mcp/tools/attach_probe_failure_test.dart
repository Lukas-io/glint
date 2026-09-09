import 'package:glint/src/mcp/tools/attach_tool.dart';
import 'package:test/test.dart';

void main() {
  group('probeFailureResponse', () {
    test('a non-resumed app is named as a native layer, not a render bug', () {
      final r = probeFailureResponse(
          lifecycle: 'inactive', lastError: null, timeoutMs: 2000);
      expect(r.isError, isTrue);
      expect(r.data?['errorKind'], 'appNotResumed');
      expect(r.summary, contains('inactive'));
      expect(r.summary, contains('native layer'));
      expect(r.nextSteps.join(' '), contains('device op:screenshot'));
      expect(r.nextSteps.join(' '), contains('mode:"device"'));
    });

    test('paused points at unlock too', () {
      final r = probeFailureResponse(
          lifecycle: 'paused', lastError: 'x', timeoutMs: 2000);
      expect(r.data?['errorKind'], 'appNotResumed');
      expect(r.nextSteps.join(' '), contains('unlock'));
    });

    test('a resumed or unknown app keeps the geometry reason', () {
      for (final lc in [null, 'resumed']) {
        final r = probeFailureResponse(
            lifecycle: lc, lastError: 'boom', timeoutMs: 3000);
        expect(r.data?['errorKind'], 'geometryResolveError');
        expect(r.data?['detail'], contains('boom'));
        expect(r.data?['detail'], contains('3000ms'));
      }
    });
  });
}
