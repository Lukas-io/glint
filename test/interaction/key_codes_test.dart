import 'package:glint/src/interaction/action.dart';
import 'package:glint/src/interaction/key_codes.dart';
import 'package:test/test.dart';

void main() {
  group('HID usages', () {
    test('every KeyName maps to a usage', () {
      for (final k in KeyName.values) {
        expect(k.hidUsage, greaterThan(0), reason: k.name);
      }
    });

    test('spot values', () {
      expect(KeyName.backspace.hidUsage, 0x2A);
      expect(KeyName.delete.hidUsage, 0x4C);
      expect(KeyName.enter.hidUsage, 0x28);
      expect(KeyName.up.hidUsage, 0x52);
      expect(KeyName.right.hidUsage, 0x4F);
    });
  });

  group('Android codes', () {
    test('every KeyName maps to a keycode', () {
      for (final k in KeyName.values) {
        expect(k.androidKeyCode, greaterThan(0), reason: k.name);
      }
    });

    test('spot values', () {
      expect(KeyName.backspace.androidKeyCode, 67);
      expect(KeyName.delete.androidKeyCode, 112);
      expect(KeyName.enter.androidKeyCode, 66);
      expect(KeyName.up.androidKeyCode, 19);
      expect(KeyName.right.androidKeyCode, 22);
    });

    test('modifier keycodes', () {
      expect(KeyModifier.cmd.androidKeyCode, 117);
      expect(KeyModifier.shift.androidKeyCode, 59);
      expect(KeyModifier.ctrl.androidKeyCode, 113);
      expect(KeyModifier.alt.androidKeyCode, 57);
    });
  });

  group('hidModifierMask', () {
    test('empty is 0, single bits, and all four is 15', () {
      expect(hidModifierMask(const {}), 0);
      expect(hidModifierMask(const {KeyModifier.cmd}), 8);
      expect(hidModifierMask(const {KeyModifier.ctrl, KeyModifier.shift}), 3);
      expect(
          hidModifierMask(const {
            KeyModifier.ctrl,
            KeyModifier.shift,
            KeyModifier.alt,
            KeyModifier.cmd,
          }),
          15);
    });
  });
}
