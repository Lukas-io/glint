import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sprung/sprung.dart';

import 'theme.dart';

/// A floating sheet with two heights: drag up or tap the handle to show [more], drag down to hide it.
class RideSheet extends StatefulWidget {
  const RideSheet({super.key, required this.children, this.more = const []});

  final List<Widget> children;
  final List<Widget> more;

  @override
  State<RideSheet> createState() => _RideSheetState();
}

class _RideSheetState extends State<RideSheet> {
  bool _open = false;

  /// How far the current drag has moved, so a slow drag counts as well as a fling.
  double _dy = 0;

  void _set(bool open) {
    if (open != _open && (widget.more.isNotEmpty || !open)) setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.delta.dy,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150 || _dy < -40) _set(true);
        if (v > 150 || _dy > 40) _set(false);
      },
      child: Container(
        // Float clear of the home indicator / gesture bar, not on top of it.
        margin: EdgeInsets.fromLTRB(8, 0, 8, math.max(8, MediaQuery.viewPaddingOf(context).bottom)),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
        decoration: ShapeDecoration(color: Colors.white, shape: _shape(), shadows: floatShadow),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 520),
          curve: Sprung(28),
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                button: widget.more.isNotEmpty,
                label: _open ? 'Show less' : 'Show more',
                onTap: () => _set(!_open),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _set(!_open),
                  child: Container(
                    height: 21,
                    alignment: Alignment.topCenter,
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(color: handle, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 360),
                switchInCurve: Sprung(28),
                layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topCenter, children: [...prev, ?cur]),
                child: Column(
                  key: ValueKey(_open),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _spaced(_open && widget.more.isNotEmpty ? widget.more : widget.children),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// iOS gets Apple's continuous corners; Android a plain round.
  static ShapeBorder _shape() => Platform.isIOS
      ? RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(32))
      : RoundedRectangleBorder(borderRadius: BorderRadius.circular(28));

  List<Widget> _spaced(List<Widget> w) => [
    for (var i = 0; i < w.length; i++) ...[if (i > 0) const SizedBox(height: 16), w[i]],
  ];
}
