import 'target.dart';

/// One thing the agent wants the device to do.
///
/// v1 surface (matches §4 scope): tap, swipe, type, hardware button.
/// Long-press / double-tap / drag / scroll derive from these primitives —
/// the [Interactor] composes them in P2's later iteration. Multi-touch
/// (pinch / rotate) is deliberately out (§5).
///
/// Action values are immutable and self-describing. [label] feeds the
/// agent action log (§8.5) and the [ActionResult.summary] line.
sealed class Action {
  const Action();

  /// Short, human-readable shape — used in logs and result summaries.
  String get label;
}

/// Single tap at the centre of [target].
///
/// For a [SymbolicTarget], the centre comes from Module B's lazy
/// resolution at action time. For a [CoordinateTarget], the coord is
/// taken as-is.
class Tap extends Action {
  const Tap(this.target);
  final Target target;

  @override
  String get label => 'tap $target';
}

/// Tap-and-hold for [durationMs] before release. v1 default: 600ms,
/// matching iOS's standard long-press recognition threshold.
class LongPress extends Action {
  const LongPress(this.target, {this.durationMs = 600});
  final Target target;
  final int durationMs;

  @override
  String get label => 'long_press $target ($durationMs ms)';
}

/// Two quick taps. v1 default: 80ms gap, matching iOS's standard
/// double-tap interval (max ~250ms; below ~50ms can read as a noisy
/// single tap).
class DoubleTap extends Action {
  const DoubleTap(this.target, {this.gapMs = 80});
  final Target target;
  final int gapMs;

  @override
  String get label => 'double_tap $target';
}

/// Single-finger drag from [from] to [to] over [durationMs]. Both points
/// are resolved at action time. v1 default duration: 250ms.
class Swipe extends Action {
  const Swipe(this.from, this.to, {this.durationMs = 250});
  final Target from;
  final Target to;
  final int durationMs;

  @override
  String get label => 'swipe $from -> $to ($durationMs ms)';
}

/// Type literal text into the currently focused field. Glint does not
/// take responsibility for focusing a field first — the agent is expected
/// to tap the field, then issue [Type].
class TypeText extends Action {
  const TypeText(this.text);
  final String text;

  @override
  String get label => 'type "${_truncate(text, 32)}"';
}

/// Press one of the physical/system buttons.
enum HardwareButton {
  /// iOS HOME / Android HOME.
  home,

  /// Android BACK (no iOS equivalent — backend refuses on iOS).
  back,

  /// Side / lock button.
  lock,

  /// Volume up.
  volumeUp,

  /// Volume down.
  volumeDown,

  /// Android task switcher / recent apps. No iOS equivalent.
  appSwitcher,
}

class PressHardwareButton extends Action {
  const PressHardwareButton(this.button);
  final HardwareButton button;

  @override
  String get label => 'press ${button.name}';
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';
