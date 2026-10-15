import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'activity.dart';

final _plugin = FlutterLocalNotificationsPlugin();
var _nextId = 1;

/// Where a tapped notification sends the app; main wires it to the router.
void Function(String route)? openRoute;

/// The message a notification's Reply action quotes; the chat screen listens for it.
final replyTo = ValueNotifier<String?>(null);

Future<void> initNotifications() async {
  await _plugin.initialize(
    settings: InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        notificationCategories: [
          DarwinNotificationCategory('message', actions: [
            DarwinNotificationAction.plain('reply', 'Reply', options: {DarwinNotificationActionOption.foreground}),
            DarwinNotificationAction.plain('read', 'Mark as read', options: {DarwinNotificationActionOption.foreground}),
          ]),
        ],
      ),
    ),
    onDidReceiveNotificationResponse: _open,
  );
  await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  final launch = await _plugin.getNotificationAppLaunchDetails();
  final response = launch?.notificationResponse;
  if ((launch?.didNotificationLaunchApp ?? false) && response != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _open(response));
  }
}

void _open(NotificationResponse r) {
  switch (r.actionId) {
    case 'read':
      logActivity('Marked Amara\'s message as read');
      openRoute?.call('/activity');
    case 'reply':
      replyTo.value = r.payload;
      openRoute?.call('/chat');
    default:
      openRoute?.call('/chat');
  }
}

/// Posts Amara's message as a notification with Reply and Mark as read, as a chat app does while it is in the background.
Future<void> notifyMessage(String text) => _plugin.show(
      id: _nextId++,
      title: 'Amara',
      body: text,
      payload: text,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          importance: Importance.high,
          priority: Priority.high,
          actions: [
            AndroidNotificationAction('reply', 'Reply', showsUserInterface: true),
            AndroidNotificationAction('read', 'Mark as read', showsUserInterface: true),
          ],
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: 'message'),
      ),
    );
