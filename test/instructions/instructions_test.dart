// Pin the shape of kGlintInstructions so accidental edits surface as test
// failures. The wire-delivery check goes in the MCP smoke test.

import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('kGlintInstructions', () {
    test('starts with the one-line elevator pitch', () {
      expect(
        kGlintInstructions.split('\n').first,
        startsWith('glint lets you drive a running Flutter app'),
      );
    });

    test('contains every required section header', () {
      const requiredSections = [
        '## Workflow',
        '## Addressing',
        '## Recovery',
        '## Gotchas',
        '## Examples',
      ];
      for (final h in requiredSections) {
        expect(kGlintInstructions, contains(h),
            reason: '$h missing from kGlintInstructions');
      }
    });

    test('covers every GlintErrorKind in the recovery section', () {
      // Extract the recovery section so we don't accidentally match a kind
      // name that happens to appear elsewhere (e.g. a tool's gotcha).
      final start = kGlintInstructions.indexOf('## Recovery');
      final end = kGlintInstructions.indexOf('## Gotchas');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final recovery = kGlintInstructions.substring(start, end);

      for (final kind in GlintErrorKind.values) {
        expect(recovery, contains('`${kind.name}`'),
            reason: 'GlintErrorKind.${kind.name} missing from Recovery');
      }
    });

    test('mentions every affordance marker', () {
      const markers = ['`*`', '`>`', '`<>`', '`-`'];
      for (final m in markers) {
        expect(kGlintInstructions, contains(m));
      }
    });

    test('is short — under 3500 chars (token-efficiency guardrail)', () {
      // If you genuinely need more room, raise this ceiling AND justify the
      // bump in the commit message. Every char is a system-prompt token cost.
      expect(kGlintInstructions.length, lessThan(3500));
    });
  });
}
