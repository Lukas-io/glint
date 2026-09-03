@TestOn('mac-os')
library;

import 'dart:io';

import 'package:glint/interaction.dart';
import 'package:test/test.dart';

/// Write a minimal built Runner.app/Info.plist under [projectDir] for [variant].
void _writeBuiltApp(
  String projectDir,
  String variant, {
  required String bundleId,
  String? displayName,
  String? bundleName,
}) {
  final appDir =
      Directory('$projectDir/build/ios/$variant/Runner.app')
        ..createSync(recursive: true);
  final entries = <String>[
    '<key>CFBundleIdentifier</key><string>$bundleId</string>',
    if (displayName != null)
      '<key>CFBundleDisplayName</key><string>$displayName</string>',
    if (bundleName != null)
      '<key>CFBundleName</key><string>$bundleName</string>',
  ];
  File('${appDir.path}/Info.plist').writeAsStringSync(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0"><dict>${entries.join()}</dict></plist>\n',
  );
}

void main() {
  const discovery = DeviceDiscovery();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('glint_appinfo_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('appInfoForProject', () {
    test('reads bundle id + display name from the built sim app', () async {
      _writeBuiltApp(tmp.path, 'iphonesimulator',
          bundleId: 'com.sangatechnologies.eat', displayName: 'Sanga Eats');
      final info = await discovery.appInfoForProject(tmp.path);
      expect(info, isNotNull);
      expect(info!.$1, 'com.sangatechnologies.eat');
      expect(info.$2, 'Sanga Eats');
    });

    test('falls back to CFBundleName when no display name', () async {
      _writeBuiltApp(tmp.path, 'iphonesimulator',
          bundleId: 'com.app.x', bundleName: 'X App');
      final info = await discovery.appInfoForProject(tmp.path);
      expect(info!.$2, 'X App');
    });

    test('prefers the simulator build over the device build', () async {
      _writeBuiltApp(tmp.path, 'iphoneos',
          bundleId: 'com.device.build', displayName: 'Device');
      _writeBuiltApp(tmp.path, 'iphonesimulator',
          bundleId: 'com.sim.build', displayName: 'Sim');
      final info = await discovery.appInfoForProject(tmp.path);
      expect(info!.$1, 'com.sim.build');
    });

    test('returns null when the project has no built product', () async {
      expect(await discovery.appInfoForProject(tmp.path), isNull);
    });

    test('two projects yield their OWN identities (no cross-talk)', () async {
      final other = Directory.systemTemp.createTempSync('glint_appinfo2_');
      addTearDown(() => other.deleteSync(recursive: true));
      _writeBuiltApp(tmp.path, 'iphonesimulator',
          bundleId: 'com.sangatechnologies.eat', displayName: 'Sanga Eats');
      _writeBuiltApp(other.path, 'iphonesimulator',
          bundleId: 'com.gskinner.flutter.wonders', displayName: 'Wonderous');
      expect((await discovery.appInfoForProject(tmp.path))!.$1,
          'com.sangatechnologies.eat');
      expect((await discovery.appInfoForProject(other.path))!.$1,
          'com.gskinner.flutter.wonders');
    });
  });
}
