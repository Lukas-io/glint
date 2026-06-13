import 'target.dart';

sealed class Action {
  const Action();

  /// One-line description for logs and result summaries.
  String get label;

  /// Just the target portion (or composite) — used in success summaries.
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

/// Cross-platform hardware button identity. Each backend declares which
/// subset it supports via [BackendCapabilities.hardwareButtons].
enum HardwareButton {
  home,
  back,
  lock,
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
