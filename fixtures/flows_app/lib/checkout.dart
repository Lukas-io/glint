import 'package:flutter/material.dart';

import 'activity.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _qty = {'Jollof rice bowl': 1, 'Chapman': 2, 'Puff-puff (6)': 1};
  static const _price = {'Jollof rice bowl': 4500, 'Chapman': 1800, 'Puff-puff (6)': 1200};
  final _promo = TextEditingController();
  String? _promoError;
  int _discount = 0;
  String _payment = 'Card ending 4242';
  bool _paying = false;
  int _attempts = 0;

  int get _subtotal => _qty.entries.fold(0, (s, e) => s + e.value * _price[e.key]!);

  void _applyPromo() => setState(() {
        if (_promo.text.trim().toUpperCase() == 'GLINT10') {
          _discount = (_subtotal * .1).round();
          _promoError = null;
        } else {
          _discount = 0;
          _promoError = 'That code is not valid';
        }
      });

  Future<void> _pay() async {
    setState(() => _paying = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _paying = false);
    _attempts++;
    if (_attempts == 1) {
      final retry = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Payment failed'),
          content: const Text('Your bank declined the charge. Try again?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Try again')),
          ],
        ),
      );
      if (retry == true) await _pay();
      return;
    }
    logActivity('Paid ₦${_subtotal - _discount} with $_payment');
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _Receipt(total: _subtotal - _discount, payment: _payment)));
  }

  @override
  void dispose() {
    _promo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                const SliverAppBar.large(title: Text('Your order')),
                SliverList.list(children: [
                  for (final item in _qty.keys)
                    ListTile(
                      title: Text(item),
                      subtitle: Text('₦${_price[item]}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Fewer $item',
                          onPressed: _qty[item]! > 0 ? () => setState(() => _qty[item] = _qty[item]! - 1) : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('${_qty[item]}'),
                        IconButton(
                          tooltip: 'More $item',
                          onPressed: () => setState(() => _qty[item] = _qty[item]! + 1),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ]),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _promo,
                          decoration: InputDecoration(labelText: 'Promo code', errorText: _promoError, border: const OutlineInputBorder()),
                        ),
                      ),
                      TextButton(onPressed: _applyPromo, child: const Text('Apply')),
                    ]),
                  ),
                  RadioGroup<String>(
                    groupValue: _payment,
                    onChanged: (v) => setState(() => _payment = v!),
                    child: const Column(children: [
                      RadioListTile(value: 'Card ending 4242', title: Text('Card ending 4242')),
                      RadioListTile(value: 'Bank transfer', title: Text('Bank transfer')),
                      RadioListTile(value: 'Pay on delivery', title: Text('Pay on delivery')),
                    ]),
                  ),
                  ListTile(title: const Text('Subtotal'), trailing: Text('₦$_subtotal')),
                  if (_discount > 0) ListTile(title: const Text('Promo'), trailing: Text('−₦$_discount')),
                  ListTile(title: const Text('Total'), trailing: Text('₦${_subtotal - _discount}', style: Theme.of(context).textTheme.titleLarge)),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: _paying || _subtotal == 0 ? null : _pay,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      child: Text('Pay ₦${_subtotal - _discount}'),
                    ),
                  ),
                  const SizedBox(height: 400),
                ]),
              ],
            ),
            if (_paying)
              const ColoredBox(
                color: Colors.black38,
                child: Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: Text('Processing payment…')))),
              ),
          ],
        ),
      );
}

class _Receipt extends StatelessWidget {
  const _Receipt({required this.total, required this.payment});
  final int total;
  final String payment;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Order placed')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle, size: 72, color: Colors.green),
            Text('Paid ₦$total', style: Theme.of(context).textTheme.headlineSmall),
            Text('with $payment'),
          ]),
        ),
      );
}
