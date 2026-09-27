import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

class PreferencesPage extends StatefulWidget {
  const PreferencesPage({super.key});

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  String? _gender;
  String? _showMe;
  double _distance = 50;
  String? _error;

  void _continue() {
    if (_gender == null || _showMe == null) {
      setState(() => _error = 'Pick an option in both sections');
      return;
    }
    signup
      ..gender = _gender
      ..showMe = _showMe
      ..distanceKm = _distance;
    Navigator.of(context).pushNamed('/photos');
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 4,
      title: 'What are you\nlooking for?',
      subtitle: 'This shapes the five people we introduce you to each day.',
      cta: EmberButton(label: 'Continue', onPressed: _continue),
      children: [
        const SectionLabel('I am'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final g in ['Woman', 'Man'])
              Pill(label: g, selected: _gender == g, onTap: () => setState(() => _gender = g)),
            Pill(label: 'Non-binary', selected: false, onTap: () {}),
          ],
        ),
        const SizedBox(height: 28),
        const SectionLabel('Show me'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in ['Men', 'Women', 'Everyone'])
              Pill(label: s, selected: _showMe == s, onTap: () => setState(() => _showMe = s)),
          ],
        ),
        const SizedBox(height: 32),
        const SectionLabel('Maximum distance'),
        _DistanceSlider(value: _distance, onChanged: (v) => setState(() => _distance = v)),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: danger)),
        ],
      ],
    );
  }
}

class _DistanceSlider extends StatelessWidget {
  const _DistanceSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  static const _min = 1.0;
  static const _max = 100.0;

  void _setFrom(double dx, double width) {
    final t = (dx / width).clamp(0.0, 1.0);
    onChanged((_min + t * (_max - _min)).roundToDouble());
  }

  @override
  Widget build(BuildContext context) {
    final label = '${value.round()} km';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: -1)),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final t = (value - _min) / (_max - _min);
            return Semantics(
              slider: true,
              label: 'Maximum distance',
              value: label,
              increasedValue: '${(value + 5).clamp(_min, _max).round()} km',
              decreasedValue: '${(value - 5).clamp(_min, _max).round()} km',
              onIncrease: () => onChanged((value + 5).clamp(_min, _max)),
              onDecrease: () => onChanged((value - 5).clamp(_min, _max)),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _setFrom(d.localPosition.dx, box.maxWidth),
                onHorizontalDragUpdate: (d) => _setFrom(d.localPosition.dx, box.maxWidth),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(
                        height: 10,
                        decoration: BoxDecoration(color: surfaceHigh, borderRadius: BorderRadius.circular(5)),
                      ),
                      Container(
                        height: 10,
                        width: box.maxWidth * t,
                        decoration: BoxDecoration(gradient: emberGradient, borderRadius: BorderRadius.circular(5)),
                      ),
                      Positioned(
                        left: (box.maxWidth - 32) * t,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cream,
                            border: Border.all(color: ember, width: 4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('1 km', style: TextStyle(color: muted)),
            Text('100 km', style: TextStyle(color: muted)),
          ],
        ),
      ],
    );
  }
}
