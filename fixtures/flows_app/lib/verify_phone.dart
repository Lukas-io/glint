import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'activity.dart';

const _countries = ['🇳🇬 +234', '🇬🇭 +233', '🇰🇪 +254', '🇬🇧 +44', '🇺🇸 +1'];
const _code = '482913';

class VerifyPhoneScreen extends StatefulWidget {
  const VerifyPhoneScreen({super.key});

  @override
  State<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends State<VerifyPhoneScreen> {
  final _country = ValueNotifier(0);
  final _phone = TextEditingController();
  final _step = ValueNotifier(0);

  @override
  void dispose() {
    _country.dispose();
    _phone.dispose();
    _step.dispose();
    super.dispose();
  }

  void _pickCountry() => showCupertinoModalPopup<void>(
        context: context,
        builder: (_) => Container(
          height: 240,
          color: CupertinoColors.systemBackground.resolveFrom(context),
          child: CupertinoPicker(
            itemExtent: 36,
            scrollController: FixedExtentScrollController(initialItem: _country.value),
            onSelectedItemChanged: (i) => _country.value = i,
            children: [for (final c in _countries) Center(child: Text(c))],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: _step,
        builder: (context, step, _) => switch (step) {
          0 => _phoneStep(),
          1 => _CodeStep(phone: '${_countries[_country.value].split(' ').last} ${_phone.text}', onVerified: () => _step.value = 2),
          _ => const _Checklist(),
        },
      );

  Widget _phoneStep() => Scaffold(
        appBar: AppBar(title: const Text('Verify your account')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('We text a code to keep your account safe.'),
              const SizedBox(height: 16),
              Row(children: [
                ValueListenableBuilder(
                  valueListenable: _country,
                  builder: (_, i, _) => OutlinedButton(onPressed: _pickCountry, child: Text(_countries[i])),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(hintText: '803 555 0199', border: OutlineInputBorder()),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: _phone,
                builder: (_, _) => FilledButton(
                  onPressed: _phone.text.replaceAll(' ', '').length >= 10 ? () => _step.value = 1 : null,
                  child: const Text('Send code'),
                ),
              ),
            ],
          ),
        ),
      );
}

class _CodeStep extends StatefulWidget {
  const _CodeStep({required this.phone, required this.onVerified});
  final String phone;
  final VoidCallback onVerified;

  @override
  State<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends State<_CodeStep> {
  final _boxes = List.generate(6, (_) => TextEditingController());
  final _focus = List.generate(6, (_) => FocusNode());
  final _wrong = ValueNotifier(false);
  final _left = ValueNotifier(30);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _left.value = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left.value == 0) return t.cancel();
      _left.value--;
    });
  }

  void _changed(int i, String v) {
    _wrong.value = false;
    if (v.isNotEmpty && i < 5) _focus[i + 1].requestFocus();
    if (v.isEmpty && i > 0) _focus[i - 1].requestFocus();
    final code = _boxes.map((b) => b.text).join();
    if (code.length == 6) {
      if (code == _code) {
        widget.onVerified();
      } else {
        _wrong.value = true;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final b in _boxes) {
      b.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Enter your code')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sent to ${widget.phone}'),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (var i = 0; i < 6; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: TextField(
                          controller: _boxes[i],
                          focusNode: _focus[i],
                          autofocus: i == 0,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          maxLength: 1,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
                          onChanged: (v) => _changed(i, v),
                        ),
                      ),
                    ),
                ],
              ),
              ValueListenableBuilder(
                valueListenable: _wrong,
                builder: (_, wrong, _) => wrong ? const Text("That code doesn't match", style: TextStyle(color: Colors.red)) : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder(
                valueListenable: _left,
                builder: (_, left, _) => left > 0
                    ? Text('Resend code in 0:${left.toString().padLeft(2, '0')}')
                    : TextButton(onPressed: _startTimer, child: const Text('Resend code')),
              ),
            ],
          ),
        ),
      );
}

class _Checklist extends StatefulWidget {
  const _Checklist();

  @override
  State<_Checklist> createState() => _ChecklistState();
}

class _ChecklistState extends State<_Checklist> {
  final _done = ValueNotifier(1);
  static const _steps = ['Phone verified', 'Confirm your details', 'Add a payment method', 'Upload your ID'];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your account is almost ready')),
        body: ValueListenableBuilder(
          valueListenable: _done,
          builder: (context, done, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < _steps.length; i++)
                Opacity(
                  opacity: i > done ? .4 : 1,
                  child: Card(
                    child: ListTile(
                      leading: CircleAvatar(child: i < done ? const Icon(Icons.check) : Text('${i + 1}')),
                      title: Text(_steps[i]),
                      trailing: i == done ? const Icon(Icons.chevron_right) : null,
                      enabled: i == done,
                      onTap: i == done
                          ? () {
                              _done.value++;
                              if (_done.value == _steps.length) logActivity('Verified the account');
                            }
                          : null,
                    ),
                  ),
                ),
              if (done == _steps.length) const Center(child: Text('All set')),
            ],
          ),
        ),
      );
}
