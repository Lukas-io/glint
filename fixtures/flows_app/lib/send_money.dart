import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'activity.dart';

typedef Transfer = ({String? recipient, String amount, String pin});

class TransferNotifier extends Notifier<Transfer> {
  @override
  Transfer build() => (recipient: null, amount: '', pin: '');

  void pick(String name) => state = (recipient: name, amount: '', pin: '');

  void key(String k) {
    final a = state.amount;
    final next = switch (k) {
      '⌫' => a.isEmpty ? a : a.substring(0, a.length - 1),
      '.' => a.contains('.') ? a : '${a.isEmpty ? '0' : a}.',
      _ => a.contains('.') && a.split('.').last.length == 2 ? a : a + k,
    };
    state = (recipient: state.recipient, amount: next, pin: state.pin);
  }

  void pinKey(String k) {
    final p = state.pin;
    final next = k == '⌫' ? (p.isEmpty ? p : p.substring(0, p.length - 1)) : (p.length < 4 ? p + k : p);
    state = (recipient: state.recipient, amount: state.amount, pin: next);
  }
}

final transferProvider = NotifierProvider<TransferNotifier, Transfer>(TransferNotifier.new);

const _people = ['Chinedu Okafor', 'Lee Chen', 'Amara Bello', 'Tunde Bakare', 'Phuong Tran'];

class RecipientScreen extends ConsumerStatefulWidget {
  const RecipientScreen({super.key});

  @override
  ConsumerState<RecipientScreen> createState() => _RecipientScreenState();
}

class _RecipientScreenState extends ConsumerState<RecipientScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final matches = _people.where((p) => p.toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Send money')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or email', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 16),
          if (matches.isEmpty) const Text('No contacts match'),
          for (final p in matches)
            ListTile(
              leading: CircleAvatar(child: Text(p.split(' ').map((w) => w[0]).join())),
              title: Text(p),
              onTap: () {
                ref.read(transferProvider.notifier).pick(p);
                context.go('/send/amount');
              },
            ),
        ],
      ),
    );
  }
}

/// A keypad of plain tap targets, as fintech apps draw it: no buttons, only gesture detectors.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onKey, this.decimal = true});
  final void Function(String) onKey;
  final bool decimal;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        childAspectRatio: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9', decimal ? '.' : '', '0', '⌫'])
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: k.isEmpty ? null : () => onKey(k),
              child: Center(child: Text(k, style: const TextStyle(fontSize: 26))),
            ),
        ],
      );
}

class AmountScreen extends ConsumerWidget {
  const AmountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferProvider);
    final value = double.tryParse(t.amount) ?? 0;
    final over = value > 5000;
    return Scaffold(
      appBar: AppBar(title: Text(t.recipient ?? 'Amount')),
      body: Column(
        children: [
          const SizedBox(height: 32),
          Text('₦${t.amount.isEmpty ? '0' : t.amount}', style: Theme.of(context).textTheme.displayMedium),
          Text(over ? 'Above your ₦5,000 sending limit' : 'Sending limit ₦5,000',
              style: TextStyle(color: over ? Colors.red : null)),
          const Spacer(),
          _Keypad(onKey: ref.read(transferProvider.notifier).key),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: value > 0 && !over ? () => context.go('/send/approve') : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Next'),
            ),
          ),
        ],
      ),
    );
  }
}

class ApproveScreen extends ConsumerWidget {
  const ApproveScreen({super.key});

  static const _correctPin = '2468';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferProvider);
    final wrong = t.pin.length == 4 && t.pin != _correctPin;
    ref.listen(transferProvider, (_, next) {
      if (next.pin == _correctPin) {
        logActivity('Sent ₦${next.amount} to ${next.recipient}');
        context.go('/send/done');
      }
    });
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          Text('Enter your PIN to approve', style: Theme.of(context).textTheme.headlineSmall),
          Text('Sending ₦${t.amount} to ${t.recipient}'),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  margin: const EdgeInsets.all(8),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: i < t.pin.length ? (wrong ? Colors.red : Colors.black) : Colors.black12),
                ),
            ],
          ),
          if (wrong) const Text('Wrong PIN, try again', style: TextStyle(color: Colors.red)),
          const Spacer(),
          _Keypad(decimal: false, onKey: (k) {
            final n = ref.read(transferProvider.notifier);
            if (wrong && k != '⌫') {
              for (var i = 0; i < 4; i++) {
                n.pinKey('⌫');
              }
            }
            n.pinKey(k);
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class SentScreen extends ConsumerWidget {
  const SentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => context.go('/')),
          bottom: const TabBar(tabs: [Tab(text: 'Updates'), Tab(text: 'Details')]),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Sent ₦${t.amount}', style: Theme.of(context).textTheme.headlineMedium),
                for (final step in ['You set up your transfer', 'We took the money from your balance', 'Your transfer is complete'])
                  ListTile(leading: const Icon(Icons.check, color: Colors.green), title: Text(step)),
              ],
            ),
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(title: const Text('To'), trailing: Text(t.recipient ?? '')),
                ListTile(title: const Text('Amount'), trailing: Text('₦${t.amount}')),
                const ListTile(title: Text('Fee'), trailing: Text('₦0')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
