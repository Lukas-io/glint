import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'activity.dart';
import 'chat.dart';
import 'checkout.dart';
import 'ride.dart';
import 'send_money.dart';
import 'verify_phone.dart';

void main() => runApp(const ProviderScope(child: FlowsApp()));

final _router = GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell: shell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const _FlowList(),
            routes: [
              GoRoute(path: 'send', builder: (_, _) => const RecipientScreen(), routes: [
                GoRoute(path: 'amount', builder: (_, _) => const AmountScreen()),
                GoRoute(path: 'approve', builder: (_, _) => const ApproveScreen()),
                GoRoute(path: 'done', builder: (_, _) => const SentScreen()),
              ]),
              GoRoute(path: 'ride', builder: (_, _) => const RideScreen()),
              GoRoute(path: 'verify', builder: (_, _) => const VerifyPhoneScreen()),
              GoRoute(path: 'chat', builder: (_, _) => const ChatScreen()),
              GoRoute(path: 'checkout', builder: (_, _) => const CheckoutScreen()),
            ],
          ),
        ]),
        StatefulShellBranch(routes: [GoRoute(path: '/activity', builder: (_, _) => const ActivityScreen())]),
      ],
    ),
  ],
);

class FlowsApp extends StatelessWidget {
  const FlowsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Flows',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1B4332)),
        routerConfig: _router,
      );
}

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: shell.currentIndex,
          onTap: shell.goBranch,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: 'Flows'),
            BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Activity'),
          ],
        ),
      );
}

class _FlowList extends StatelessWidget {
  const _FlowList();

  static const _flows = [
    ('Send money', 'Riverpod · custom keypad · PIN', Icons.north_east, '/send'),
    ('Book a ride', 'Cubit · draggable sheet · painted map', Icons.local_taxi_outlined, '/ride'),
    ('Verify phone', 'ValueNotifier · code boxes · picker', Icons.verified_user_outlined, '/verify'),
    ('Chat', 'GetX · Cupertino · action sheet', Icons.chat_bubble_outline, '/chat'),
    ('Checkout', 'setState · slivers · Navigator 1', Icons.shopping_bag_outlined, '/checkout'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Flows')),
        body: ListView(
          children: [
            for (final (title, style, icon, path) in _flows)
              ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(style),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(path),
              ),
          ],
        ),
      );
}
