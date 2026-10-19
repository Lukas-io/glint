import 'package:flutter/material.dart';
import 'package:sprung/sprung.dart';

import 'theme.dart';

/// The live bar: what's happening in one line, the clock, then distance and place underneath.
class LiveBar extends StatelessWidget {
  const LiveBar({
    super.key,
    required this.title,
    required this.trailing,
    required this.left,
    required this.right,
    required this.mood,
  });

  final String title;

  /// What the headline means, not its words: it animates only when this changes, so "3 min" → "2 min" just updates.
  final String mood;
  final String trailing;
  final String left;
  final String right;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                switchInCurve: Sprung(28),
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                layoutBuilder: (cur, prev) => Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
                child: Text(
                  title,
                  key: ValueKey(mood),
                  style: t(24, w: FontWeight.w700, h: 30, ls: -0.24),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              trailing,
              style: t(15, w: FontWeight.w600, c: grey, h: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(left, style: t(15, w: FontWeight.w500, h: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                right,
                style: t(14, w: FontWeight.w600, c: blue, h: 20),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
