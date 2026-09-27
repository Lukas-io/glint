import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) => Container(
                      width: 220 + 30 * _pulse.value,
                      height: 220 + 30 * _pulse.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [gold.withValues(alpha: 0.9), ember.withValues(alpha: 0.5), ember.withValues(alpha: 0)],
                        ),
                      ),
                      child: child,
                    ),
                    child: const Icon(Icons.local_fire_department_rounded, size: 96, color: ink),
                  ),
                ),
              ),
              const Text(
                'Ember',
                style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, letterSpacing: -2, height: 1),
              ),
              const SizedBox(height: 12),
              const Text(
                'Seven days to meet someone real.\nThen the spark goes out.',
                style: TextStyle(color: muted, fontSize: 18, height: 1.4),
              ),
              const SizedBox(height: 36),
              EmberButton(
                label: 'Create account',
                onPressed: () => Navigator.of(context).pushNamed('/account'),
              ),
              const SizedBox(height: 12),
              GhostButton(
                label: 'Continue with Google',
                icon: const Text('G', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: gold)),
                onTap: () {},
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => toast(context, 'Log in is coming soon.'),
                  child: const Text('I already have an account', style: TextStyle(color: muted)),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
