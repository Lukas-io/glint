import 'target.dart';

sealed class Action {
  const Action();

  String get label;
  String get targetSummary => label;
}

class Tap extends Action {
  const Tap(this.target);
  final Target target;

  @override
  String get label => 'tap $target';

  @override
  String get targetSummary => target.toString();
}

class LongPress extends Action {
  const LongPress(this.target, {this.durationMs = 600});
  final Target target;
  final int durationMs;

  @override
  String get label => 'long_press $target ($durationMs ms)';

  @override
  String get targetSummary => target.toString();
}

class DoubleTap extends Action {
  const DoubleTap(this.target, {this.gapMs = 80});
  final Target target;
  final int gapMs;

  @override
  String get label => 'double_tap $target';

  @override
  String get targetSummary => target.toString();
}

class Swipe extends Action {
  const Swipe(this.from, this.to, {this.durationMs = 250});
  final Target from;
  final Target to;
  final int durationMs;

  @override
  String get label => 'swipe $from -> $to ($durationMs ms)';

  @override
  String get targetSummary => '$from -> $to';
}

class TypeText extends Action {
  const TypeText(this.text);
  final String text;

  @override
  String get label {
    final preview = text.length <= 32 ? text : '${text.substring(0, 31)}…';
    return 'type "$preview"';
  }
}

/// Each backend declares its supported subset via BackendCapabilities.
enum HardwareButton {
  home,
  back,
  lock,
  unlock,
  volumeUp,
  volumeDown,
  appSwitcher,
}

class PressHardwareButton extends Action {
  const PressHardwareButton(this.button);
  final HardwareButton button;

  @override
  String get label => 'press ${button.name}';
}

/// A non-printing key the keyboard can send; each backend maps it to its own code.
enum KeyName { backspace, delete, enter, tab, escape, space, up, down, left, right }

/// A modifier held down around a key press.
enum KeyModifier { cmd, shift, ctrl, alt }

class PressKey extends Action {
  const PressKey(this.key, {this.count = 1, this.modifiers = const {}});
  final KeyName key;
  final int count;
  final Set<KeyModifier> modifiers;

  @override
  String get label {
    final mods = [for (final m in modifiers) m.name].join('+');
    final base = mods.isEmpty ? key.name : '$mods+${key.name}';
    return 'key $base${count > 1 ? ' x$count' : ''}';
  }
}

/// Select all in the focused field, then backspace — the platform-native way to empty it.
class ClearField extends Action {
  const ClearField();

  @override
  String get label => 'clear field';
}
