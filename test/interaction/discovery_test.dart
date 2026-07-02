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
}
