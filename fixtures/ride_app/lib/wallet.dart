import 'dart:ui';

import 'package:flutter/material.dart';

/// A tab with its own Navigator, as a shell route builds one: sheets opened from its pages go onto this nested navigator.
class WalletTab extends StatelessWidget {
  const WalletTab({super.key});

  @override
  Widget build(BuildContext context) => Navigator(
        onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const _SellConfirmation()),
      );
}

class _SellConfirmation extends StatelessWidget {
  const _SellConfirmation();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              const Text('Sell 0.01 BTC for 1,000,000 NGN'),
              FilledButton(onPressed: () => _showSuccess(context), child: const Text('Confirm')),
            ],
          ),
        ),
      );

  void _showSuccess(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        enableDrag: false,
        isDismissible: false,
        builder: (sheet) => BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(24),
              child: PopScope(
                canPop: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    const Text('Transaction successful'),
                    FilledButton(onPressed: () => Navigator.of(sheet).pop(), child: const Text('All done')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
