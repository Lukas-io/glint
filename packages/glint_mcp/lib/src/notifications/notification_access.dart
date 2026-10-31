import 'dart:convert';
import 'dart:io';

import '../media/gallery.dart';
import '../media/permissions.dart';

const _postNotifications = 'android.permission.POST_NOTIFICATIONS';

/// Whether the app may show notifications: notAsked, denied, allowed, provisional or ephemeral; null when the device does not say.
Future<String?> readNotificationAccess(MediaDevice device, String appId) async {
  if (device.isIos) return _iosAccess(device.id, appId);
  final sdk = int.tryParse((await device.adb(['shell', 'getprop', 'ro.build.version.sdk'])).text.trim()) ?? 0;
  if (sdk < 33) return null;
  final dump = (await device.adb(['shell', 'dumpsys', 'package', appId])).text;
  return androidNotificationAccess(dump, appId);
}

/// The access a `dumpsys package` dump shows for POST_NOTIFICATIONS; a revoked permission the user answered reads denied.
String? androidNotificationAccess(String dump, String appId) {
  if (!dump.contains('Package [$appId]')) return null;
  final granted = grantedState(dump)[_postNotifications];
  if (granted == null) return requestedPermissions(dump).contains(_postNotifications) ? 'notAsked' : null;
  if (granted) return 'allowed';
  final flags =
      RegExp('${RegExp.escape(_postNotifications)}: granted=false, flags=\\[([^\\]]*)\\]').firstMatch(dump)?.group(1) ??
          '';
  return flags.contains('USER_SET') || flags.contains('USER_FIXED') ? 'denied' : 'notAsked';
}

/// SpringBoard's BulletinBoard keeps `authorizationStatus` (UNAuthorizationStatus: 0 not determined, 1 denied, 2 authorized, 3 provisional, 4 ephemeral) in each app's archived section info; an app that never asked has no entry.
Future<String?> _iosAccess(String udid, String bundleId) async {
  final file = File(
      '${Platform.environment['HOME']}/Library/Developer/CoreSimulator/Devices/$udid/data/Library/BulletinBoard/VersionedSectionInfo.plist');
  if (!file.existsSync()) return null;
  final key = 'sectionInfo.${bundleId.replaceAll('.', r'\.')}';
  final entry = await Process.run('plutil', ['-extract', key, 'raw', '-o', '-', file.path]);
  if (entry.exitCode != 0) return 'notAsked';
  final Process archive;
  try {
    archive = await Process.start('plutil', ['-p', '-']);
    archive.stdin.add(base64.decode('${entry.stdout}'.trim()));
    await archive.stdin.close();
  } on Object {
    return null;
  }
  final printed = await utf8.decodeStream(archive.stdout);
  await archive.exitCode;
  return switch (RegExp(r'"authorizationStatus" => (\d+)').firstMatch(printed)?.group(1)) {
    '0' => 'notAsked',
    '1' => 'denied',
    '2' => 'allowed',
    '3' => 'provisional',
    '4' => 'ephemeral',
    _ => null,
  };
}

/// True when [access] means the system drops the app's notifications.
bool notificationsBlocked(String? access) => access == 'notAsked' || access == 'denied';

/// One line saying the app may not show notifications and why nothing appeared.
String notificationAccessHint(String appId, String access, {required bool ios}) =>
    '$appId is not allowed to show notifications on this ${ios ? 'simulator' : 'device'} '
    '(${access == 'denied' ? 'denied' : 'never asked'}); ${ios ? 'banners are dropped' : 'they are blocked'}';

/// What to do about it: answer the prompt, or grant outright where the platform allows.
List<String> notificationAccessSteps(String appId, String access, {required bool ios}) => ios
    ? [
        if (access == 'notAsked')
          'open the screen in $appId that asks for notification permission, then notifications op:answer choice:allow while the prompt shows'
        else
          'iOS asks only once: allow it in the simulator under Settings > Notifications > the app (device mode x,y tools), or reinstall the app so it asks again',
        'simctl privacy cannot set notifications, so glint has no grant for the iOS simulator',
      ]
    : [
        'device op:privacy service:notifications action:grant bundleId:$appId grants it without the dialog',
        if (access == 'notAsked') 'or notifications op:answer choice:allow while the app\'s prompt shows',
      ];
