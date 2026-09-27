import 'package:flutter/material.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _eyeOpen = false;
  bool _terms = false;
  String? _emailError;
  String? _passwordError;
  String? _termsError;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  void _continue() {
    final email = _email.text.trim();
    setState(() {
      _emailError = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) ? null : 'Enter a valid email address';
      _passwordError = _password.text.length >= 8 ? null : 'Use at least 8 characters';
      _termsError = _terms ? null : 'Accept the terms to continue';
    });
    if (_emailError != null || _passwordError != null || _termsError != null) return;
    signup
      ..email = email
      ..password = _password.text;
    Navigator.of(context).pushNamed('/verify');
  }

  @override
  Widget build(BuildContext context) {
    final hasPassword = _password.text.isNotEmpty;
    return StepScaffold(
      step: 1,
      title: 'Start with\nthe basics',
      subtitle: 'Your email stays private. Nobody on Ember will ever see it.',
      cta: EmberButton(label: 'Continue', onPressed: _continue),
      children: [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Email',
            errorText: _emailError,
            prefixIcon: const Icon(Icons.alternate_email_rounded, color: muted),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _password,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            errorText: _passwordError,
            prefixIcon: const Icon(Icons.lock_outline_rounded, color: muted),
            suffixIcon: IconButton(
              tooltip: _eyeOpen ? 'Hide password' : 'Show password',
              icon: Icon(_eyeOpen ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: muted),
              onPressed: () => setState(() => _eyeOpen = !_eyeOpen),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            for (var i = 0; i < 4; i++)
              Expanded(
                child: Container(
                  height: 5,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: hasPassword ? const Color(0xFF5BD68A) : surfaceHigh,
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              hasPassword ? 'Strong' : 'Strength',
              style: TextStyle(color: hasPassword ? const Color(0xFF5BD68A) : muted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const SectionLabel('Why Ember is different'),
        const _Feature(icon: Icons.hourglass_bottom_rounded, title: 'Seven days', body: 'Every match lasts a week. Talk, meet, or let it go.'),
        const _Feature(icon: Icons.verified_rounded, title: 'Real people', body: 'Every profile is photo verified before it goes live.'),
        const _Feature(icon: Icons.visibility_off_rounded, title: 'No swiping marathons', body: 'Five new people a day, chosen with care.'),
        const SizedBox(height: 12),
        InkWell(
          onTap: () => setState(() {
            _terms = !_terms;
            if (_terms) _termsError = null;
          }),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Checkbox(
                  value: _terms,
                  activeColor: ember,
                  onChanged: (v) => setState(() {
                    _terms = v ?? false;
                    if (_terms) _termsError = null;
                  }),
                ),
                const Expanded(
                  child: Text('I agree to the Terms and the Privacy Policy', style: TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
        if (_termsError != null)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(_termsError!, style: const TextStyle(color: danger)),
          ),
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(20)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: gold),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(color: muted, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
