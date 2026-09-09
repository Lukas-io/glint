import 'package:glint/interaction.dart';
import 'package:test/test.dart';

void main() {
  group('AndroidDevice.devicePixelRatio', () {
    test('defaults to 1.0 (device mode: adb takes physical pixels)', () {
      const d = AndroidDevice(serial: 'emulator-5554');
      expect(d.devicePixelRatio, 1.0);
    });

    test('carries the real DPR when set (Flutter mode)', () {
      const d = AndroidDevice(serial: 'emulator-5554', devicePixelRatio: 2.625);
      expect(d.devicePixelRatio, 2.625);
    });

    test('a logical coordinate scales to physical pixels via the DPR', () {
      // Regression: a hardcoded 1.0 made logical (32,580) tap physical (32,580)
      // and silently miss its target on Android in Flutter mode.
      const d = AndroidDevice(serial: 'x', devicePixelRatio: 2.625);
      expect((32 * d.devicePixelRatio).round(), 84);
      expect((580 * d.devicePixelRatio).round(), 1523);
    });
  });
}
