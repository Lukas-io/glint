import 'package:glint/interaction.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceDiscovery.appBundlePathsForDevice', () {
    const udid = 'E223E4B6-14EB-4331-A4E9-C1031EE08261';
    String appLine(String bundleDir, String app) =>
        '/Users/x/Library/Developer/CoreSimulator/Devices/$udid/data/'
        'Containers/Bundle/Application/$bundleDir/$app.app/$app';

    test('single app on the sim → one path', () {
      final out = [
        appLine('AAAA-1111', 'Runner'),
        '/usr/libexec/some-daemon',
      ].join('\n');
      final paths = DeviceDiscovery.appBundlePathsForDevice(out, udid);
      expect(paths, hasLength(1));
      expect(paths.single, endsWith('Runner.app'));
    });

    test('same app on multiple ps lines dedupes to one path', () {
      final out = [
        appLine('AAAA-1111', 'Runner'),
        '${appLine('AAAA-1111', 'Runner')} --extra-helper-arg',
      ].join('\n');
      expect(DeviceDiscovery.appBundlePathsForDevice(out, udid), hasLength(1));
    });

    test('two distinct apps on one sim → ambiguous (two paths)', () {
      final out = [
        appLine('AAAA-1111', 'Sanga'),
        appLine('BBBB-2222', 'Wonderous'),
      ].join('\n');
      expect(DeviceDiscovery.appBundlePathsForDevice(out, udid), hasLength(2));
    });

    test('apps on OTHER devices are ignored', () {
      const other = '11111111-2222-3333-4444-555555555555';
      final out = [
        appLine('AAAA-1111', 'Sanga'),
        '/Users/x/Library/Developer/CoreSimulator/Devices/$other/data/'
            'Containers/Bundle/Application/CCCC/Other.app/Other',
      ].join('\n');
      final paths = DeviceDiscovery.appBundlePathsForDevice(out, udid);
      expect(paths, hasLength(1));
      expect(paths.single, contains('Sanga.app'));
    });

    test('no matching app → empty', () {
      expect(
        DeviceDiscovery.appBundlePathsForDevice('/usr/bin/nothing', udid),
        isEmpty,
      );
    });
  });

  group('DeviceDiscovery.linkFromCommandLine', () {
    const udid = '41C10380-3598-406B-B7D4-0943A4A71115';
    const booted = [
      BootedDevice(platform: DevicePlatform.ios, id: udid, name: 'iPhone 17'),
      BootedDevice(
          platform: DevicePlatform.ios,
          id: 'E223E4B6-14EB-4331-A4E9-C1031EE08261',
          name: 'iPhone Air'),
    ];
    Future<(String?, String?)?> noBundle(String _) async => null;

    test('CoreSimulator app path wins and carries the app name', () async {
      final link = await DeviceDiscovery.linkFromCommandLine(
        '/x/CoreSimulator/Devices/$udid/data/Containers/Bundle/Application/1/Runner.app/Runner',
        booted,
        noBundle,
      );
      expect(link?.deviceId, udid);
      expect(link?.appName, 'Runner');
    });

    test('flutter_tools -d <udid> resolves the device', () async {
      final link = await DeviceDiscovery.linkFromCommandLine(
        'dart flutter_tools.snapshot run -d $udid --machine',
        booted,
        noBundle,
      );
      expect(link?.deviceId, udid);
    });

    test('-d <name prefix> resolves against booted sims', () async {
      final link = await DeviceDiscovery.linkFromCommandLine(
        'flutter run -d "iPhone Air"',
        booted,
        noBundle,
      );
      expect(link?.deviceId, 'E223E4B6-14EB-4331-A4E9-C1031EE08261');
    });

    test('a command line without a device is null', () async {
      final link = await DeviceDiscovery.linkFromCommandLine(
        'dart development-service --vm-service-uri=http://127.0.0.1:1/',
        booted,
        noBundle,
      );
      expect(link, isNull);
    });
  });

  group('resolveAdbPath', () {
    test('an explicit path is returned as-is', () {
      expect(resolveAdbPath('/opt/adb', const {}), '/opt/adb');
    });

    test('nothing on PATH or in SDK homes is null', () {
      expect(resolveAdbPath(null, const {'PATH': '/nonexistent', 'HOME': '/nonexistent'}), isNull);
    });
  });
}
