import 'package:flutter/material.dart';

class AddBankScreen extends StatefulWidget {
  const AddBankScreen({super.key});

  @override
  State<AddBankScreen> createState() => _AddBankScreenState();
}

class _AddBankScreenState extends State<AddBankScreen> {
  final _form = GlobalKey<FormState>();
  bool _saved = false;

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'This field is required' : null;

  String? _tenDigits(String? v) => (v == null || !RegExp(r'^\d{10}$').hasMatch(v)) ? 'Must be 10 digits' : null;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add bank account')),
        body: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(decoration: const InputDecoration(labelText: 'Account name'), validator: _required),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Account number'),
                keyboardType: TextInputType.number,
                validator: _tenDigits,
              ),
              TextFormField(decoration: const InputDecoration(labelText: 'Bank'), validator: _required),
              TextFormField(decoration: const InputDecoration(labelText: 'Branch'), validator: _required),
              TextFormField(decoration: const InputDecoration(labelText: 'Sort code'), validator: _required),
              TextFormField(decoration: const InputDecoration(labelText: 'Reference'), validator: _required),
              const SizedBox(height: 24),
              _BrandButton(
                label: 'Save account',
                onTap: () => setState(() => _saved = _form.currentState!.validate()),
              ),
              if (_saved) const Padding(padding: EdgeInsets.only(top: 16), child: Text('Account saved')),
            ],
          ),
        ),
      );
}

class _BrandButton extends StatelessWidget {
  const _BrandButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ),
        ),
      );
}
