import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

const _all = [
  'Hiking', 'Coffee', 'Jazz', 'Cooking', 'Travel', 'Yoga',
  'Photography', 'Gaming', 'Books', 'Running', 'Art', 'Wine',
  'Dogs', 'Cats', 'Movies', 'Dancing', 'Climbing', 'Karaoke',
];

class InterestsPage extends StatefulWidget {
  const InterestsPage({super.key});

  @override
  State<InterestsPage> createState() => _InterestsPageState();
}

class _InterestsPageState extends State<InterestsPage> {
  final _picked = <String>{};

  void _toggle(String interest) {
    setState(() {
      if (_picked.contains(interest)) {
        _picked.remove(interest);
      } else if (_picked.length >= 5) {
        toast(context, 'You can pick up to 5.');
      } else {
        _picked.add(interest);
      }
    });
  }

  void _continue() {
    if (_picked.length < 3) {
      toast(context, 'Pick at least 3 interests.');
      return;
    }
    signup.interests
      ..clear()
      ..addAll(_picked);
    Navigator.of(context).pushNamed('/prompts');
  }

  @override
  Widget build(BuildContext context) {
    final shown = _picked.isEmpty ? 0 : _picked.length - 1;
    return StepScaffold(
      step: 6,
      title: 'What lights\nyou up?',
      subtitle: 'Pick 3 to 5. We use them to start your first conversations.',
      cta: EmberButton(label: 'Continue', onPressed: _continue),
      children: [
        Row(
          children: [
            Text(
              '$shown of 3 picked',
              style: TextStyle(color: shown >= 3 ? gold : muted, fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final i in _all) Pill(label: i, selected: _picked.contains(i), onTap: () => _toggle(i)),
          ],
        ),
      ],
    );
  }
}
