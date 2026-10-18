import 'package:flutter/material.dart';

/// A brand button built from Material, InkWell and Text, the way design systems usually do it.
class KitButton extends StatelessWidget {
  const KitButton({super.key, required this.label, required this.onPressed, this.color = const Color(0xFF2D6A4F)});

  final String label;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    borderRadius: BorderRadius.circular(28),
    child: InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}
