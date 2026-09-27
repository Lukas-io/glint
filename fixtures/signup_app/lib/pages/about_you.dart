import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

const _firstYear = 1950;
const _lastYear = 2010;

class AboutYouPage extends StatefulWidget {
  const AboutYouPage({super.key});

  @override
  State<AboutYouPage> createState() => _AboutYouPageState();
}

class _AboutYouPageState extends State<AboutYouPage> {
  final _name = TextEditingController();
  final _day = FixedExtentScrollController(initialItem: 0);
  final _month = FixedExtentScrollController(initialItem: 0);
  final _year = FixedExtentScrollController(initialItem: 2000 - _firstYear);
  int _d = 1;
  int _m = 1;
  int _y = 2000;
  String? _nameError;
  String? _ageError;

  DateTime get _birthday {
    final lastDay = DateUtils.getDaysInMonth(_y, _m);
    return DateTime(_y, _m, _d.clamp(1, lastDay));
  }

  int get _realAge {
    final now = DateTime.now();
    final b = _birthday;
    var age = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) age--;
    return age;
  }

  int get _shownAge => DateTime.now().year - _birthday.year - 1;

  void _continue() {
    setState(() {
      _nameError = _name.text.trim().isEmpty ? 'Tell us what to call you' : null;
      _ageError = _realAge < 18 ? 'You need to be 18 or older to use Ember' : null;
    });
    if (_nameError != null || _ageError != null) return;
    signup
      ..name = _name.text.trim()
      ..birthday = _birthday;
    Navigator.of(context).pushNamed('/preferences');
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 3,
      title: 'Who are\nyou?',
      subtitle: 'Your first name and age show on your profile. You cannot change your birthday later.',
      cta: EmberButton(label: 'Continue', onPressed: _continue),
      children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'First name', errorText: _nameError),
        ),
        const SizedBox(height: 28),
        const SectionLabel('Birthday'),
        Container(
          height: 200,
          decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(24)),
          child: Stack(
            children: [
              Center(
                child: Container(
                  height: 44,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: ember.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _Wheel(
                      controller: _day,
                      labels: [for (var i = 1; i <= 31; i++) '$i'],
                      onChanged: (i) => setState(() => _d = i + 1),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: _Wheel(
                      controller: _month,
                      labels: months,
                      onChanged: (i) => setState(() => _m = i + 1),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _Wheel(
                      controller: _year,
                      labels: [for (var y = _firstYear; y <= _lastYear; y++) '$y'],
                      onChanged: (i) => setState(() => _y = _firstYear + i),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Icon(Icons.cake_rounded, color: gold, size: 20),
            const SizedBox(width: 8),
            Text(
              '${formatDate(_birthday)} · you are $_shownAge',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        if (_ageError != null) ...[
          const SizedBox(height: 10),
          Text(_ageError!, style: const TextStyle(color: danger)),
        ],
      ],
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({required this.controller, required this.labels, required this.onChanged});

  final FixedExtentScrollController controller;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: 44,
      diameterRatio: 1.6,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: labels.length,
        builder: (context, index) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.animateToItem(
            index,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          ),
          child: Center(
            child: Text(labels[index], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
