import '../../interaction.dart';
import '../../perception.dart' show Scene;
import 'session.dart';

/// Keys sent before the tapped field takes focus are lost, and on Android `input text` also needs the soft keyboard fully shown; waits up to 2s for both.
Future<bool> awaitReadyToType(GlintSession session) async {
  final needsKeyboard = session.device.platform == DevicePlatform.android;
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  double? lastInset;
  DateTime? focusedAt;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final focused = await session.focusedFieldText() != null;
      if (focused && !needsKeyboard) return true;
      if (focused) {
        focusedAt ??= DateTime.now();
        // The inset turns non-zero as the keyboard starts sliding in; it takes keys once it stops moving.
        final inset = (await session.uiState()).keyboardBottomPx;
        if (inset > 0 && inset == lastInset) return true;
        // No soft keyboard at all (a hardware keyboard is attached): focus is enough.
        if (inset == 0 && DateTime.now().difference(focusedAt) > const Duration(milliseconds: 600)) {
          return true;
        }
        lastInset = inset;
      }
    } on Object {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  return false;
}

/// The visible parent a refused tap on a faded input named, when the refusal carried one.
String? visibleParentOf(ActionResult refused) {
  final parent = refused.extra['visibleParent'];
  return !refused.ok && parent is String ? parent : null;
}

/// Focuses the faded input [inputId] the way a person does: taps its visible [parentId], then confirms a text field took focus.
Future<ActionResult> focusThroughParent(GlintSession session, Scene scene, String inputId, String parentId) async {
  final tapped = await session.interactor.run(scene, Tap(SymbolicTarget(parentId)));
  if (!tapped.ok) return tapped;
  if (!await awaitReadyToType(session)) {
    return ActionResult.failure(
      action: Tap(SymbolicTarget(inputId)),
      summary: 'tapped $parentId (the visible parent of $inputId) but no text field took focus',
      errorKind: GlintErrorKind.notHittable,
      error: '$inputId is faded to opacity 0 and its visible parent $parentId did not pass the tap on to it',
      physicalCenter: tapped.physicalCenter,
      logicalCenter: tapped.logicalCenter,
      devicePixelRatio: tapped.devicePixelRatio,
      nextSteps: const [
        'get_scene: find the control that opens the input (an amount, a keypad field) and tap it',
        'refuseNotHittable:false taps the hidden field itself',
      ],
      extra: {'faded': true, 'visibleParent': parentId},
    );
  }
  return ActionResult.success(
    action: Tap(SymbolicTarget(inputId)),
    summary: 'focused $inputId through its visible parent $parentId',
    physicalCenter: tapped.physicalCenter,
    logicalCenter: tapped.logicalCenter,
    devicePixelRatio: tapped.devicePixelRatio,
    painted: tapped.painted,
    hittable: tapped.hittable,
    warnings: tapped.warnings,
  );
}
