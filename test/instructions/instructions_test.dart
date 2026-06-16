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
        // Behavioural layer (B8 — human mindset + feedback + behaviours + anti-patterns)
        '## Mindset',
        '## Feedback loop',
        '## Behaviors',
        '## Anti-patterns',
        // Mechanics
        '## Workflow',
        '## Addressing',
        '## Recovery',
        '## Gotchas',
        '## Tool surface',
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

    test('anti-patterns block explicitly forbids the Run-1 escape hatches', () {
      // These are the specific anti-patterns documented in Finding 8 that
      // caused the 12-minute thrash in Run 1. Must be present verbatim.
      const forbidden = ['flutter driver', 'simctl', 'AppleScript'];
      for (final f in forbidden) {
        expect(kGlintInstructions, contains(f),
            reason: '"$f" anti-pattern missing from instructions');
      }
    });

    test('is short — under 5500 chars (token-efficiency guardrail)', () {
      // Ceiling raised from 3500 → 5500 for the B8 behavioural layer.
      // Finding 8: the instruction layer may move Run 2 results more than
      // several code fixes combined. The increase is load-bearing.
      // If you need more room, raise AND justify in the commit message.
      expect(kGlintInstructions.length, lessThan(5500));
    });
  });
}
