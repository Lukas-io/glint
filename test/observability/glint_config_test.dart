import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('GlintConfig', () {
    test('defaults match what the tools previously hardcoded', () {
      final c = GlintConfig();
      expect(c.readyTimeoutMs, 5000);
      expect(c.settleCeilingMs, 5000);
      expect(c.settleQuietFrames, 3);
      expect(c.scrollMaxScrolls, 8);
      expect(c.scrollAmountFraction, 0.6);
    });

    test('set accepts valid values and rejects bad ones', () {
      final c = GlintConfig();
      expect(c.set('readyTimeoutMs', 1200), isNull);
      expect(c.readyTimeoutMs, 1200);

      expect(c.set('readyTimeoutMs', -1), isNotNull);
      expect(c.set('readyTimeoutMs', 'fast'), isNotNull);
      expect(c.readyTimeoutMs, 1200, reason: 'rejected sets leave value alone');
    });

    test('scrollAmountFraction is constrained to (0, 1]', () {
      final c = GlintConfig();
      expect(c.set('scrollAmountFraction', 0), isNotNull);
      expect(c.set('scrollAmountFraction', 1.5), isNotNull);
      expect(c.set('scrollAmountFraction', 0.5), isNull);
      expect(c.scrollAmountFraction, 0.5);
    });

    test('unknown key returns an error', () {
      final c = GlintConfig();
      final err = c.set('frobnicator', 42);
      expect(err, contains('unknown'));
    });

    test('toJson round-trips current state', () {
      final c = GlintConfig()..readyTimeoutMs = 3500;
      expect(c.toJson()['readyTimeoutMs'], 3500);
    });
  });
}
