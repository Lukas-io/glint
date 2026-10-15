import 'gallery.dart';
import 'permissions.dart';

/// The runtime permissions behind each privacy service, named as `simctl privacy` names them where iOS has the service.
Map<String, List<String>> androidPrivacyServices(int sdk) => {
      'notifications': [if (sdk >= 33) 'android.permission.POST_NOTIFICATIONS'],
      'microphone': ['android.permission.RECORD_AUDIO'],
      'camera': ['android.permission.CAMERA'],
      'contacts': ['android.permission.READ_CONTACTS', 'android.permission.WRITE_CONTACTS'],
      'contacts-limited': ['android.permission.READ_CONTACTS'],
      'location': ['android.permission.ACCESS_FINE_LOCATION', 'android.permission.ACCESS_COARSE_LOCATION'],
      'location-always': [
        'android.permission.ACCESS_FINE_LOCATION',
        'android.permission.ACCESS_COARSE_LOCATION',
        'android.permission.ACCESS_BACKGROUND_LOCATION',
      ],
      'photos': sdk >= 33
          ? ['android.permission.READ_MEDIA_IMAGES', 'android.permission.READ_MEDIA_VIDEO']
          : ['android.permission.READ_EXTERNAL_STORAGE'],
      'media-library':
          sdk >= 33 ? ['android.permission.READ_MEDIA_AUDIO'] : ['android.permission.READ_EXTERNAL_STORAGE'],
      'calendar': ['android.permission.READ_CALENDAR', 'android.permission.WRITE_CALENDAR'],
      'motion': ['android.permission.ACTIVITY_RECOGNITION'],
      'phone': ['android.permission.READ_PHONE_STATE', 'android.permission.CALL_PHONE'],
      'sms': ['android.permission.READ_SMS', 'android.permission.RECEIVE_SMS', 'android.permission.SEND_SMS'],
    };

/// What a privacy change did on Android: the commands it ran and the state read back.
typedef AndroidPrivacyOutcome = ({List<String> applied, String state, String? caution});

/// Grants, revokes or resets [service] for [appId]; `screen-capture` goes through app ops (the MediaProjection consent), everything else through runtime permissions.
Future<AndroidPrivacyOutcome> setAndroidPrivacy(MediaDevice device, String appId, String action, String service) async {
  final dump = (await device.adb(['shell', 'dumpsys', 'package', appId])).text;
  if (!dump.contains('Package [$appId]')) throw PermissionRefused('dumpsys package found no $appId', unknownApp: true);
  if (service == 'screen-capture') return _screenCapture(device, appId, action);

  final sdk = int.tryParse((await device.adb(['shell', 'getprop', 'ro.build.version.sdk'])).text.trim()) ?? 0;
  final services = androidPrivacyServices(sdk);
  final requested = requestedPermissions(dump);
  final perms = service == 'all'
      ? {for (final list in services.values) ...list}.where(requested.contains).toList()
      : services[service];
  if (perms == null) {
    throw PermissionUnsupported('Android has no "$service" permission', [
      'services: ${[...services.keys, 'screen-capture', 'all'].join(', ')}'
    ]);
  }
  if (perms.isEmpty) {
    throw PermissionUnsupported(
        service == 'notifications'
            ? 'notifications need no permission before Android 13 (API 33); this device is API $sdk'
            : '$appId declares none of the permissions this needs',
        const ['nothing to change']);
  }
  final declared = [
    for (final p in perms)
      if (requested.contains(p)) p
  ];
  if (declared.isEmpty) throw PermissionRefused('$appId requests none of ${perms.join(', ')}', notDeclared: true);

  final applied = <String>[];
  Future<void> pm(List<String> args) async {
    final r = await device.adb(['shell', 'pm', ...args]);
    final out = '${r.text}\n${r.errTail()}';
    if (!r.ok || out.contains('Exception') || out.contains('Error:')) throw PermissionRefused(out.trim());
    applied.add('pm ${args.join(' ')}');
  }

  for (final p in declared) {
    switch (action) {
      case 'grant':
        await pm(['grant', appId, p]);
      case 'revoke':
        await pm(['revoke', appId, p]);
        await pm(['set-permission-flags', appId, p, 'user-set']);
      default:
        await pm(['revoke', appId, p]);
        await pm(['clear-permission-flags', appId, p, 'user-set', 'user-fixed']);
    }
  }
  final now = grantedState((await device.adb(['shell', 'dumpsys', 'package', appId])).text);
  final wrong = [
    for (final p in declared)
      if (now[p] != (action == 'grant')) p
  ];
  if (wrong.isNotEmpty) {
    throw PermissionRefused('after the change ${wrong.join(', ')} still read granted=${action != 'grant'}');
  }
  final skipped = [
    for (final p in perms)
      if (!requested.contains(p)) p.split('.').last
  ];
  return (
    applied: applied,
    state:
        '${action == 'grant' ? 'granted' : action == 'revoke' ? 'denied' : 'not asked'}: ${declared.map((p) => p.split('.').last).join(', ')}'
            '${skipped.isEmpty ? '' : ' (not declared, left alone: ${skipped.join(', ')})'}',
    caution: action == 'grant'
        ? null
        : 'Android stops an app when a permission is taken away; relaunch it before the next action',
  );
}

Future<AndroidPrivacyOutcome> _screenCapture(MediaDevice device, String appId, String action) async {
  final mode = switch (action) { 'grant' => 'allow', 'revoke' => 'ignore', _ => 'default' };
  final r = await device.adb(['shell', 'appops', 'set', appId, 'PROJECT_MEDIA', mode]);
  if (!r.ok || r.text.contains('Error')) throw PermissionRefused('${r.text}\n${r.errTail()}'.trim());
  final now = (await device.adb(['shell', 'appops', 'get', appId, 'PROJECT_MEDIA'])).text.trim();
  final read =
      RegExp(r'PROJECT_MEDIA: (\w+)').firstMatch(now)?.group(1) ?? (now.contains('No operations') ? 'default' : now);
  if (read != mode) throw PermissionRefused('PROJECT_MEDIA reads $read after setting $mode');
  return (
    applied: ['appops set $appId PROJECT_MEDIA $mode'],
    state: 'screen capture app op (PROJECT_MEDIA): $read',
    caution: null,
  );
}
