import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

const _code = '482915';

class VerifyPage extends StatefulWidget {
  const VerifyPage({super.key});

  @override
  State<VerifyPage> createState() => _VerifyPageState();
}

class _VerifyPageState extends State<VerifyPage> {
  final _controller = TextEditingController();
  final _node = FocusNode();
  bool _banner = false;
  String? _error;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _error = null));
    _bannerTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _banner = true);
    });
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _controller.dispose();
    _node.dispose();
    super.dispose();
  }

  String get _entered => _controller.text;

  void _verify() {
    if (_entered.length < 6) {
      setState(() => _error = 'Enter all 6 digits');
      return;
    }
    if (_entered != _code) {
      setState(() => _error = 'That code is not right. Check the latest email from Ember.');
      return;
    }
    Navigator.of(context).pushNamed('/about');
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 2,
      title: 'Check your\ninbox',
      subtitle: 'We sent a 6-digit code to ${signup.email.isEmpty ? 'your email' : signup.email}.',
      cta: EmberButton(label: 'Verify', onPressed: _verify),
      overlay: _banner
          ? Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 12,
              right: 12,
              child: GestureDetector(
                onTap: () => setState(() => _banner = false),
                child: Material(
                  elevation: 12,
                  color: const Color(0xFFF3EEE9),
                  borderRadius: BorderRadius.circular(22),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: ember,
                          radius: 18,
                          child: Icon(Icons.mail_rounded, color: ink, size: 18),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Mail · now', style: TextStyle(color: Color(0xFF6E6560), fontSize: 12)),
                              SizedBox(height: 2),
                              Text(
                                'Ember: your code is $_code',
                                style: TextStyle(color: ink, fontWeight: FontWeight.w700, fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : null,
      children: [
        SizedBox(
          height: 68,
          child: Stack(
            children: [
              IgnorePointer(
                child: Row(
                  children: [
                    for (var i = 0; i < 6; i++) ...[
                      if (i == 3) const SizedBox(width: 10),
                      Expanded(child: _Box(digit: i < _entered.length ? _entered[i] : '', active: _node.hasFocus && i == _entered.length.clamp(0, 5))),
                    ],
                  ],
                ),
              ),
              Positioned.fill(
                child: TextField(
                  controller: _controller,
                  focusNode: _node,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  showCursor: false,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: Colors.transparent, fontSize: 1),
                  onTap: () => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Verification code',
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    labelStyle: TextStyle(color: Colors.transparent),
                    counterText: '',
                    filled: false,
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: const TextStyle(color: danger)),
        ],
        const SizedBox(height: 28),
        const Row(
          children: [
            Text("Didn't get it? ", style: TextStyle(color: muted, fontSize: 15)),
            Text(
              'Resend code',
              style: TextStyle(
                color: gold,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
                decorationColor: gold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.digit, required this.active});

  final String digit;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: active ? ember : surfaceHigh, width: active ? 1.5 : 1),
      ),
      child: Center(
        child: Text(
          digit.isEmpty ? '·' : digit,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: digit.isEmpty ? muted : cream),
        ),
      ),
    );
  }
}
