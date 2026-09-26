import 'action.dart';

/// USB HID usage-page-7 code for a [KeyName], the value the iOS bridge sends.
extension KeyHidUsage on KeyName {
  int get hidUsage => switch (this) {
        KeyName.backspace => 0x2A,
        KeyName.delete => 0x4C,
        KeyName.enter => 0x28,
        KeyName.tab => 0x2B,
        KeyName.escape => 0x29,
        KeyName.space => 0x2C,
        KeyName.up => 0x52,
        KeyName.down => 0x51,
        KeyName.left => 0x50,
        KeyName.right => 0x4F,
      };
}

/// Android `KEYCODE_*` for a [KeyName], the value `adb shell input keyevent` takes.
extension KeyAndroidCode on KeyName {
  int get androidKeyCode => switch (this) {
        KeyName.backspace => 67, // KEYCODE_DEL
        KeyName.delete => 112, // KEYCODE_FORWARD_DEL
        KeyName.enter => 66,
        KeyName.tab => 61,
        KeyName.escape => 111,
        KeyName.space => 62,
        KeyName.up => 19,
        KeyName.down => 20,
        KeyName.left => 21,
        KeyName.right => 22,
      };
}

/// Android `KEYCODE_*` for a left-hand [KeyModifier], for `input keycombination`.
extension ModifierAndroidCode on KeyModifier {
  int get androidKeyCode => switch (this) {
        KeyModifier.cmd => 117, // META_LEFT
        KeyModifier.shift => 59, // SHIFT_LEFT
        KeyModifier.ctrl => 113, // CTRL_LEFT
        KeyModifier.alt => 57, // ALT_LEFT
      };
}

/// The bridge modifier mask: bit i means HID usage 0xE0 + i (1 ctrl, 2 shift, 4 alt, 8 cmd).
int hidModifierMask(Set<KeyModifier> modifiers) {
  var mask = 0;
  for (final m in modifiers) {
    mask |= switch (m) {
      KeyModifier.ctrl => 1,
      KeyModifier.shift => 2,
      KeyModifier.alt => 4,
      KeyModifier.cmd => 8,
    };
  }
  return mask;
}
