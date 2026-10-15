import 'gallery.dart';

/// The permissions `media op:permission` handles, by their glint names.
const permissionNames = {'camera', 'microphone', 'photos'};

/// The actions it takes: grant and deny set the answer, reset makes the app ask again, limited gives photo access to selected items only.
const permissionActions = {'grant', 'deny', 'reset', 'limited'};

/// A permission change the platform has no supported way to make.
class PermissionUnsupported implements Exception {
  PermissionUnsupported(this.reason, this.nextSteps);
  final String reason;
  final List<String> nextSteps;
}

/// The device refused the change; [notDeclared] when the app never asked for the permission in its manifest.
class PermissionRefused implements Exception {
  PermissionRefused(this.detail, {this.notDeclared = false, this.unknownApp = false});
  final String detail;
  final bool notDeclared;
  final bool unknownApp;
}

/// What a permission change did: the platform calls it made and what the agent should know about the app.
typedef PermissionOutcome = ({List<String> applied, String? caution});

/// Sets [permission] for [appId] on [device] to [action].
Future<PermissionOutcome> setPermission(MediaDevice device, String appId, String permission, String action) =>
    device.isIos ? _ios(device, appId, permission, action) : _android(device, appId, permission, action);

Future<PermissionOutcome> _ios(MediaDevice device, String appId, String permission, String action) async {
  final prompt =
      'open the screen in the app that asks for it, then answer the system prompt (tap Allow or Don\'t Allow; '
      'get_scene lists it with the XCUITest runner, or read it from a screenshot)';
  if (permission == 'camera') {
    throw PermissionUnsupported('the iOS simulator keeps no camera permission that simctl can set', [prompt]);
  }
  if (action == 'limited') {
    throw PermissionUnsupported('the iOS simulator cannot set limited photo access from outside the app',
        ['$prompt; choose Select Photos for limited access']);
  }
  final service = permission == 'microphone' ? 'microphone' : 'photos';
  final verb = switch (action) { 'grant' => 'grant', 'deny' => 'revoke', _ => 'reset' };
  final run = await device.simctl(['privacy', device.id, verb, service, appId]);
  if (!run.ok) throw PermissionRefused(run.errTail());
  return (
    applied: ['simctl privacy $verb $service $appId'],
    caution: action == 'grant'
        ? null
        : 'iOS may end the app when access is taken away or reset; reattach if get_scene loses it',
  );
}

Future<PermissionOutcome> _android(MediaDevice device, String appId, String permission, String action) async {
  final sdk = int.tryParse((await device.adb(['shell', 'getprop', 'ro.build.version.sdk'])).text.trim()) ?? 0;
  const selected = 'android.permission.READ_MEDIA_VISUAL_USER_SELECTED';
  final perms = switch (permission) {
    'camera' => ['android.permission.CAMERA'],
    'microphone' => ['android.permission.RECORD_AUDIO'],
    _ when sdk >= 33 => ['android.permission.READ_MEDIA_IMAGES', 'android.permission.READ_MEDIA_VIDEO'],
    _ => ['android.permission.READ_EXTERNAL_STORAGE'],
  };
  if (action == 'limited' && (permission != 'photos' || sdk < 34)) {
    throw PermissionUnsupported(
        permission != 'photos'
            ? 'limited access exists for photos only'
            : 'limited photo access needs Android 14 (API 34); this device is API $sdk',
        const ['grant or deny instead']);
  }
  final dump = await device.adb(['shell', 'dumpsys', 'package', appId]);
  if (dump.text.contains('Unable to find package') || !dump.text.contains('Package [$appId]')) {
    throw PermissionRefused('dumpsys package found no $appId', unknownApp: true);
  }
  final requested = requestedPermissions(dump.text);
  final wanted = [...perms, if (action == 'limited') selected];
  final missing = [
    for (final p in wanted)
      if (!requested.contains(p)) p
  ];
  if (missing.length == wanted.length || (action == 'limited' && missing.contains(selected))) {
    throw PermissionRefused('$appId requests none of ${missing.join(', ')}', notDeclared: true);
  }
  final declared = [
    for (final p in perms)
      if (requested.contains(p)) p
  ];
  final applied = <String>[];
  Future<void> pm(List<String> args) async {
    final r = await device.adb(['shell', 'pm', ...args]);
    final out = '${r.text}\n${r.errTail()}';
    if (!r.ok || out.contains('Exception') || out.contains('Error:')) {
      throw PermissionRefused(out.trim(),
          notDeclared: out.contains('has not requested permission'),
          unknownApp: out.contains('Unknown package') || out.contains('package not found'));
    }
    applied.add('pm ${args.join(' ')}');
  }

  switch (action) {
    case 'grant':
      for (final p in declared) {
        await pm(['grant', appId, p]);
      }
    case 'deny':
      for (final p in declared) {
        await pm(['revoke', appId, p]);
        await pm(['set-permission-flags', appId, p, 'user-set']);
      }
    case 'reset':
      for (final p in [
        ...declared,
        if (permission == 'photos' && sdk >= 34 && requested.contains(selected)) selected
      ]) {
        await pm(['revoke', appId, p]);
        await pm(['clear-permission-flags', appId, p, 'user-set', 'user-fixed']);
      }
    case 'limited':
      for (final p in declared) {
        await pm(['revoke', appId, p]);
      }
      await pm(['grant', appId, selected]);
  }
  final now = grantedState((await device.adb(['shell', 'dumpsys', 'package', appId])).text);
  final expectGranted = action == 'grant';
  final wrong = [
    for (final p in declared)
      if (now[p] != expectGranted) p
  ];
  if (wrong.isNotEmpty) {
    throw PermissionRefused('after the change ${wrong.join(', ')} still read granted=${!expectGranted}');
  }
  return (
    applied: applied,
    caution: action == 'grant'
        ? null
        : 'Android stops an app when a permission is taken away; reattach (or relaunch it) before the next action',
  );
}

/// The permissions listed under `requested permissions:` in `dumpsys package` output.
Set<String> requestedPermissions(String dump) {
  final out = <String>{};
  var inside = false;
  for (final line in dump.split('\n')) {
    final t = line.trim();
    if (t == 'requested permissions:') {
      inside = true;
      continue;
    }
    if (!inside) continue;
    final name = RegExp(r'^([A-Za-z0-9_.]+)(?::\s.*)?$').firstMatch(t)?.group(1);
    if (name == null) break;
    out.add(name);
  }
  return out;
}

/// Each runtime permission's `granted=` value in `dumpsys package` output.
Map<String, bool> grantedState(String dump) => {
      for (final m in RegExp(r'([a-zA-Z0-9_.]+\.permission\.[A-Z0-9_]+): granted=(true|false)').allMatches(dump))
        m.group(1)!: m.group(2) == 'true',
    };

/// One line on what to do with an unknown name.
String permissionUsage() => 'permission: ${permissionNames.join(' | ')}; action: ${permissionActions.join(' | ')}';
