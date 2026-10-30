import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sprung/sprung.dart';

import 'theme.dart';

/// Initials in a grey circle, with an optional rating badge under it.
class Avatar extends StatelessWidget {
  const Avatar(this.initials, {super.key, this.size = 40, this.rating});

  final String initials;
  final double size;
  final String? rating;

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: line, shape: BoxShape.circle),
      child: Text(
        initials,
        style: t(size < 48 ? 15 : 17, w: FontWeight.w700, c: grey),
      ),
    );
    if (rating == null) return circle;
    return SizedBox(
      width: size,
      height: size + 6,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          circle,
          Positioned(
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: chipShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(rating!, style: t(11, w: FontWeight.w600, h: 15)),
                  const SizedBox(width: 2),
                  const Icon(Icons.star_rounded, size: 11, color: ink),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A grey circular icon button.
class RoundButton extends StatelessWidget {
  const RoundButton(this.icon, {super.key, required this.label, this.onTap, this.size = 44});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: soft,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap ?? () {},
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: 19, color: ink),
          ),
        ),
      ),
    );
  }
}

/// A white circle floating on the map.
class MapButton extends StatelessWidget {
  const MapButton(this.icon, {super.key, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Container(
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: chipShadow),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap ?? () {},
            child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 19, color: ink)),
          ),
        ),
      ),
    );
  }
}

/// The collapsed person row: avatar, a bold line, a grey line, and a call button.
class CompactPerson extends StatelessWidget {
  const CompactPerson({super.key, required this.initials, required this.top, required this.sub, required this.call});

  final String initials;
  final String top;
  final String sub;
  final String call;

  @override
  Widget build(BuildContext context) {
    return _Divided(
      top: 14,
      child: Row(
        children: [
          Avatar(initials),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(top, style: t(16, w: FontWeight.w700, h: 21, ls: 0.16)),
                const SizedBox(height: 1),
                Text(
                  sub,
                  style: t(13, c: grey, h: 17),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          RoundButton(LucideIcons.phone, label: call),
        ],
      ),
    );
  }
}

/// The full person card used when the sheet is pulled up.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.initials,
    required this.rating,
    required this.name,
    required this.sub,
    required this.big,
    required this.bigSub,
    required this.message,
    required this.call,
  });

  final String initials, rating, name, sub, big, bigSub, message, call;

  @override
  Widget build(BuildContext context) {
    return _Divided(
      top: 16,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Avatar(initials, size: 52, rating: rating),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: t(16, w: FontWeight.w600, h: 21)),
                      const SizedBox(height: 2),
                      Text(sub, style: t(13, c: grey, h: 17)),
                    ],
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(big, style: t(20, w: FontWeight.w700, h: 25, ls: 0.2)),
                  const SizedBox(height: 2),
                  Text(bigSub, style: t(13, c: grey, h: 17)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(22)),
                  child: Text(message, style: t(14, c: grey)),
                ),
              ),
              const SizedBox(width: 10),
              RoundButton(LucideIcons.phone, label: call),
            ],
          ),
        ],
      ),
    );
  }
}

/// Grey grouped list rows with chevrons.
class ActionRows extends StatelessWidget {
  const ActionRows(this.items, {super.key});

  final List<(IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++)
            Container(
              height: 52,
              decoration: BoxDecoration(
                border: i == 0 ? null : const Border(top: BorderSide(color: Color(0xFFE6E7EB))),
              ),
              child: Row(
                children: [
                  Icon(items[i].$1, size: 19, color: ink),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(items[i].$2, style: t(15, w: FontWeight.w600)),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 16, color: Color(0xFFA0A3AB)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The one filled blue button.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: blue,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: t(17, w: FontWeight.w700),
        ),
        child: Text(label),
      ),
    );
  }
}

/// A secondary action sitting beside the primary button, as plain text.
class TextAction extends StatelessWidget {
  const TextAction(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: t(16, w: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _Divided extends StatelessWidget {
  const _Divided({required this.top, required this.child});

  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.only(top: top),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: soft)),
    ),
    child: child,
  );
}

/// Appears above the sheet once the user moves the map; tapping it hands the camera back.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.6,
        duration: const Duration(milliseconds: 420),
        curve: Sprung(28),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 4),
            child: MapButton(LucideIcons.locateFixed, label: 'Re-center', onTap: onTap),
          ),
        ),
      ),
    );
  }
}
