import 'dart:io';

import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  bool _busy = false;

  Future<void> _create() async {
    setState(() => _busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/done', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final b = signup.birthday;
    return StepScaffold(
      step: 8,
      title: 'Looking\ngood',
      subtitle: 'Check your details. Your profile goes live the moment you create your account.',
      cta: EmberButton(label: 'Create account', busy: _busy, onPressed: _create),
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(24)),
          child: Column(
            children: [
              if (signup.photoPath != null)
                Container(
                  height: 120,
                  alignment: Alignment.bottomLeft,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    image: DecorationImage(image: FileImage(File(signup.photoPath!)), fit: BoxFit.cover),
                  ),
                  child: const Text('Your cover', style: TextStyle(color: cream, fontWeight: FontWeight.w800)),
                ),
              if (signup.photoPath != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: CircleAvatar(radius: 44, backgroundImage: FileImage(File(signup.photoPath!))),
                ),
              _Row('Email', signup.email),
              _Row('Name', signup.name),
              _Row('Birthday', b == null ? '' : formatDate(b)),
              _Row('I am', signup.gender ?? ''),
              _Row('Show me', signup.showMe ?? ''),
              _Row('Distance', 'Up to ${signup.distanceKm.round()} mi'),
              _Row('Interests', signup.interests.join(', ')),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
          decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(20)),
          child: Row(
            children: [
              const Expanded(
                child: Text('Match notifications', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Switch(
                value: !signup.notifications,
                activeThumbColor: ember,
                onChanged: (v) => setState(() => signup.notifications = !v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            signup.notifications
                ? 'We will tell you the moment someone matches with you.'
                : 'Notifications are off. You will only see matches when you open Ember.',
            style: const TextStyle(color: muted, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'review_${label.toLowerCase().replaceAll(' ', '_')}',
      child: _content(),
    );
  }

  Widget _content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label, style: const TextStyle(color: muted))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
          GestureDetector(
            onTap: () {},
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('Edit', style: TextStyle(color: gold, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
