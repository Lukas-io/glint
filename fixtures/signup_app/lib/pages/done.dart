import 'dart:convert';

import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';

class DonePage extends StatefulWidget {
  const DonePage({super.key});

  @override
  State<DonePage> createState() => _DonePageState();
}

class _DonePageState extends State<DonePage> {
  @override
  void initState() {
    super.initState();
    debugPrint('EMBER_PROFILE ${jsonEncode(signup.toJson())}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              ShaderMask(
                shaderCallback: (r) => emberGradient.createShader(r),
                child: const Icon(Icons.local_fire_department_rounded, size: 88, color: Colors.white),
              ),
              const SizedBox(height: 20),
              Text(
                'Welcome to Ember, ${signup.name}',
                style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: -1.2, height: 1.05),
              ),
              const SizedBox(height: 14),
              const Text(
                'Your seven days start now. Your first five introductions arrive tomorrow at 9 am.',
                style: TextStyle(color: muted, fontSize: 18, height: 1.4),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}
