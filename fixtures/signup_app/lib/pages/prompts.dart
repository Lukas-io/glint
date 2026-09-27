import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

const _prompts = [
  'My perfect Sunday',
  'The way to win me over',
  'A green flag I look for',
];

class PromptsPage extends StatefulWidget {
  const PromptsPage({super.key});

  @override
  State<PromptsPage> createState() => _PromptsPageState();
}

class _PromptsPageState extends State<PromptsPage> {
  int _selected = 0;
  final _answer = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 7,
      title: 'Say something\nreal',
      subtitle: 'Answer one prompt so people have an easy way to start talking. Optional.',
      action: TextButton(
        onPressed: () => Navigator.of(context).pushNamed('/review'),
        child: const Text('Skip', style: TextStyle(color: muted, fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      cta: EmberButton(label: 'Done', onPressed: () {}),
      children: [
        for (var i = 0; i < _prompts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: _selected == i ? surfaceHigh : surface,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => setState(() => _selected = i),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _prompts[i],
                          style: TextStyle(fontSize: 16, fontWeight: _selected == i ? FontWeight.w700 : FontWeight.w500),
                        ),
                      ),
                      Icon(
                        _selected == i ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        color: _selected == i ? ember : muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: _answer,
          maxLines: 4,
          maxLength: 150,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: 'Your answer to "${_prompts[_selected]}"'),
        ),
      ],
    );
  }
}
