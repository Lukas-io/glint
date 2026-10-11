import 'dart:io';

import '../media/gallery.dart';
import '../media/permissions.dart';

/// The location access `location op:permission` sets.
const locationAccessValues = ['whileUsing', 'always', 'approximate', 'deny', 'reset'];

const _fine = 'android.permission.ACCESS_FINE_LOCATION';
const _coarse = 'android.permission.ACCESS_COARSE_LOCATION';
const _background = 'android.permission.ACCESS_BACKGROUND_LOCATION';

/// What the app may do with location: notAsked, denied, once, whileUsing, always or approximate (Android coarse only); null when the device does not say.
Future<String?> readLocationAccess(MediaDevice device, String appId) async {
  if (device.isIos) return _iosAccess(device.id, appId);
  final dump = (await device.adb(['shell', 'dumpsys', 'package', appId])).text;
  if (!dump.contains('Package [$appId]')) return null;
  return androidAccess(dump);
}

/// The location access a `dumpsys package` dump shows; a revoked permission the user answered reads denied, one never answered notAsked.
String androidAccess(String dump) {
  final granted = grantedState(dump);
  String flags(String p) => RegExp('${RegExp.escape(p)}: granted=(?:true|false), flags=\\[([^\\]]*)\\]').firstMatch(dump)?.group(1) ?? '';
  if (granted[_fine] == true || granted[_coarse] == true) {
    if (granted[_background] == true) return 'always';
    if (flags(granted[_fine] == true ? _fine : _coarse).contains('ONE_TIME')) return 'once';
    return granted[_fine] == true ? 'whileUsing' : 'approximate';
  }
  return flags(_fine).contains('USER_SET') || flags(_fine).contains('USER_FIXED') ? 'denied' : 'notAsked';
}

/// The simulator's locationd keeps each app's answer in `clients.plist`: Authorization 1 denied, 2 while using, 4 always; Allow Once only sets TemporaryAuthorization.
Future<String?> _iosAccess(String udid, String bundleId) async {
  final file = File('${Platform.environment['HOME']}/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Caches/locationd/clients.plist');
  if (!file.existsSync()) return 'notAsked';
  Future<String?> value(String field) async {
    final key = 'i${bundleId.replaceAll('.', r'\.')}:.$field';
    final r = await Process.run('plutil', ['-extract', key, 'raw', '-o', '-', file.path]);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
  }

  return switch (await value('Authorization')) {
    '1' => 'denied',
    '2' => 'whileUsing',
    '4' => 'always',
    null => await value('TemporaryAuthorization') == '1' ? 'once' : 'notAsked',
    final other => 'unknown ($other)',
  };
}

/// Sets [appId]'s location access on [device] to [access] and reads it back.
Future<PermissionOutcome> setLocationAccess(MediaDevice device, String appId, String access) =>
    device.isIos ? _iosSet(device, appId, access) : _androidSet(device, appId, access);

Future<PermissionOutcome> _iosSet(MediaDevice device, String appId, String access) async {
  if (access == 'approximate') {
    throw PermissionUnsupported('the iOS simulator has no way to set approximate location from outside the app',
        const ['use whileUsing, or test reduced accuracy on Android']);
  }
  final (verb, service) = switch (access) {
    'whileUsing' => ('grant', 'location'),
    'always' => ('grant', 'location-always'),
    'deny' => ('revoke', 'location'),
    _ => ('reset', 'location'),
  };
  final run = await device.simctl(['privacy', device.id, verb, service, appId]);
  if (!run.ok) throw PermissionRefused(run.errTail());
  return (
    applied: ['simctl privacy $verb $service $appId'],
    caution: access == 'reset'
        ? 'the app gets an error on its running location stream; it asks again (the system prompt) the next time it requests location'
        : null,
  );
}

Future<PermissionOutcome> _androidSet(MediaDevice device, String appId, String access) async {
  final dump = (await device.adb(['shell', 'dumpsys', 'package', appId])).text;
  if (!dump.contains('Package [$appId]')) throw PermissionRefused('dumpsys package found no $appId', unknownApp: true);
  final requested = requestedPermissions(dump);
  if (!requested.contains(_fine) && !requested.contains(_coarse)) {
    throw PermissionRefused('$appId requests neither $_fine nor $_coarse', notDeclared: true);
  }
  if (access == 'always' && !requested.contains(_background)) {
    throw PermissionRefused('$appId does not request $_background, so Android never lets it use location in the background',
        notDeclared: true);
  }
  final applied = <String>[];
  Future<void> pm(List<String> args) async {
    final r = await device.adb(['shell', 'pm', ...args]);
    final out = '${r.text}\n${r.errTail()}';
    if (!r.ok || out.contains('Exception') || out.contains('Error:')) throw PermissionRefused(out.trim());
    applied.add('pm ${args.join(' ')}');
  }

  final all = [for (final p in [_fine, _coarse, _background]) if (requested.contains(p)) p];
  Future<void> grant(String p) async {
    if (requested.contains(p)) await pm(['grant', appId, p]);
  }

  Future<void> revoke(String p, {bool answered = true}) async {
    if (!requested.contains(p)) return;
    await pm(['revoke', appId, p]);
    await pm(answered ? ['set-permission-flags', appId, p, 'user-set'] : ['clear-permission-flags', appId, p, 'user-set', 'user-fixed']);
  }

  switch (access) {
    case 'whileUsing':
      await grant(_fine);
      await grant(_coarse);
      await revoke(_background);
    case 'always':
      await grant(_fine);
      await grant(_coarse);
      await grant(_background);
    case 'approximate':
      await revoke(_fine);
      await grant(_coarse);
      await revoke(_background);
    case 'deny':
      for (final p in all) {
        await revoke(p);
      }
    default:
      for (final p in all) {
        await revoke(p, answered: false);
      }
  }
  final now = androidAccess((await device.adb(['shell', 'dumpsys', 'package', appId])).text);
  final expected = access == 'reset' ? 'notAsked' : (access == 'deny' ? 'denied' : access);
  if (now != expected) throw PermissionRefused('after the change the app reads $now, not $expected');
  return (
    applied: applied,
    caution: access == 'whileUsing' || access == 'always'
        ? null
        : 'Android stops an app when location is taken away; relaunch it (attach launch:) before the next action',
  );
}

/// Turns the Android emulator's location services on or off and reads the switch back.
Future<bool> setAndroidLocationServices(MediaDevice device, bool on) async {
  await device.adb(['shell', 'cmd', 'location', 'set-location-enabled', '$on']);
  return (await device.adb(['shell', 'cmd', 'location', 'is-location-enabled'])).text.trim() == '$on';
}

/// Whether [appId] can get location in the background at all: the `location` background mode on iOS, ACCESS_BACKGROUND_LOCATION declared on Android; null when unknown.
Future<bool?> readBackgroundCapable(MediaDevice device, String appId) async {
  if (!device.isIos) {
    final dump = (await device.adb(['shell', 'dumpsys', 'package', appId])).text;
    return dump.contains('Package [$appId]') ? requestedPermissions(dump).contains(_background) : null;
  }
  final container = await device.simctl(['get_app_container', device.id, appId, 'app']);
  if (!container.ok) return null;
  final r = await Process.run('plutil', ['-extract', 'UIBackgroundModes', 'json', '-o', '-', '${container.text.trim()}/Info.plist']);
  if (r.exitCode != 0) return false;
  return '${r.stdout}'.contains('"location"');
}
