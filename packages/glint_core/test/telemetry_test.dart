import 'dart:io';

import 'package:glint_core/glint_core.dart';
import 'package:test/test.dart';

void main() {
  group('TelemetrySwitches', () {
    const switches = TelemetrySwitches('GLINT_NETWORK_');

    test('sharing is off until the prefix TELEMETRY variable opts in', () {
      expect(switches.sharingOffReason(const {}), contains('set GLINT_NETWORK_TELEMETRY=on'));
      expect(switches.sharingOffReason(const {'GLINT_NETWORK_TELEMETRY': 'on'}), isNull);
    });

    test('DO_NOT_TRACK wins over an opt-in', () {
      expect(
          switches.sharingOffReason(const {'GLINT_NETWORK_TELEMETRY': 'on', 'DO_NOT_TRACK': '1'}),
          'DO_NOT_TRACK is set');
    });

    test('NO_USAGE stops usage sharing but not crash reports', () {
      const env = {'GLINT_NETWORK_TELEMETRY': 'on', 'GLINT_NETWORK_NO_USAGE': 'true'};
      expect(switches.sharingOffReason(env), 'GLINT_NETWORK_NO_USAGE is set');
      expect(switches.sharingOffReason(env, usage: false), isNull);
      expect(switches.usageDisabled(env), isTrue);
      expect(switches.disabled(env), isFalse);
    });

    test('another package\'s variables are ignored', () {
      expect(switches.sharingOffReason(const {'GLINT_TELEMETRY': 'on'}), isNotNull);
    });
  });

  test('installId is random, stable per data dir, and reveals nothing', () {
    final a = Directory.systemTemp.createTempSync('id-a');
    final b = Directory.systemTemp.createTempSync('id-b');
    addTearDown(() {
      a.deleteSync(recursive: true);
      b.deleteSync(recursive: true);
    });
    final id = installId(a.path);
    expect(id, matches(RegExp(r'^[0-9a-f]{24}$')));
    expect(installId(a.path), id);
    expect(installId(b.path), isNot(id));
  });

  test('truthyEnv accepts the usual spellings', () {
    for (final v in ['true', '1', 'YES', ' on ']) {
      expect(truthyEnv(v), isTrue, reason: v);
    }
    for (final v in [null, '', 'false', '0', 'off']) {
      expect(truthyEnv(v), isFalse, reason: '$v');
    }
  });
}
