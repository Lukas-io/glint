import 'package:flutter/material.dart';

/// Finished flows, newest first, shown on the Activity tab.
final activityLog = ValueNotifier<List<String>>(const []);

void logActivity(String entry) => activityLog.value = [entry, ...activityLog.value];

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Activity')),
        body: ValueListenableBuilder(
          valueListenable: activityLog,
          builder: (context, entries, _) => entries.isEmpty
              ? const Center(child: Text('Nothing yet'))
              : ListView(children: [for (final e in entries) ListTile(leading: const Icon(Icons.check_circle_outline), title: Text(e))]),
        ),
      );
}
