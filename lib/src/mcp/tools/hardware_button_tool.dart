import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../envelope.dart';
import '../post_action.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// iOS Xcode 26: lock + unlock + home + back (left-edge swipe) wired. Others
/// (volumeUp/Down, appSwitcher) raise UnsupportedBackendAction.
/// See source-of-truth §13.
class HardwareButtonTool extends GlintTool {
  const HardwareButtonTool();

  @override
  Tool get definition => Tool(
        name: 'hardware_button',
        description:
            'Press a physical hardware button. iOS Sim: lock + unlock '
            '(Face ID auth via Darwin notification + bottom-edge swipe) + '
            'home (Face ID gesture) + back (the left-edge back gesture, since '
            'iPhone has no back button) all work on Xcode 26. Returns the app '
            'lifecycle after the press (resumed / inactive / paused) and, for '
            'lock / unlock, whether the device reports itself locked, so you '
            'know it took. Available buttons are listed in attach\'s reply.',
        inputSchema: ObjectSchema(
          properties: {
            'button': Schema.string(
              description:
                  'Button name. One of: ${HardwareButton.values.map((b) => b.name).join(', ')}.',
            ),
          },
          required: ['button'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = args['button']! as String;

    final button = enumByName(HardwareButton.values, name);
    if (button == null) {
      return StructuredResponse.error(
        summary: 'unknown hardware button: $name',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: [
          'use one of: ${HardwareButton.values.map((b) => b.name).join(', ')}'
        ],
      );
    }

    // Device mode: hardware buttons are OS-level — go straight to the backend
    // (no Flutter scene / interactor available).
    if (session.isDeviceMode) {
      try {
        await session.backend.pressHardwareButton(button);
      } on UnsupportedBackendAction catch (e) {
        return StructuredResponse.error(
          summary: '${session.backend.label}: ${button.name} not supported',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: e.detail,
        );
      } on Object catch (e) {
        return StructuredResponse.error(
          summary: 'hardware button ${button.name} failed',
          errorKind: GlintErrorKind.backendToolError,
          detail: '$e',
        );
      }
      final locked = await _lockStateFor(session, button);
      return StructuredResponse(
        summary: locked == null
            ? 'pressed ${button.name}'
            : 'pressed ${button.name}, device ${locked ? 'locked' : 'unlocked'}',
        data: {'ok': true, 'mode': 'device', if (locked != null) 'locked': locked},
        warnings: [
          if (button == HardwareButton.unlock && locked == true) _stillLocked,
        ],
      );
    }

    final pre =
        button == HardwareButton.back ? await snapshotPreAction(session) : null;
    final scene = await session.reader.readSummary();
    try {
      final result = await session.interactor.run(
        scene,
        PressHardwareButton(button),
      );
      var response = StructuredResponse.fromActionResult(result);
      if (!response.isError && button == HardwareButton.back) {
        response = await _backOutcome(session, scene, response, pre);
      }
      if (!response.isError) {
        // The "what happened" for a hardware button is a lifecycle change, not
        // a scene diff. Read it best-effort (home may background the app and
        // make the eval fail — that itself signals it took).
        final lifecycle = await _settledLifecycle(session, button);
        final locked = await _lockStateFor(session, button);
        final stuck = switch (button) {
          HardwareButton.home => lifecycle == 'resumed',
          HardwareButton.lock =>
            locked == false || (locked == null && lifecycle == 'resumed'),
          _ => false,
        };
        final stillLocked = button == HardwareButton.unlock && locked == true;
        final backMissed =
            button == HardwareButton.back && response.data?['changed'] == false;
        final summary = StringBuffer(response.summary);
        if (lifecycle != null) summary.write(', app is $lifecycle');
        if (locked != null) summary.write(', device ${locked ? 'locked' : 'unlocked'}');
        return response.copyWith(
          summary: summary.toString(),
          data: {
            ...?response.data,
            if (lifecycle != null) 'lifecycle': lifecycle,
            if (locked != null) 'locked': locked,
          },
          warnings: [
            if (stuck)
              'the ${button.name} press may not have registered: the app never '
                  'left the foreground; try once more or use `device op:screenshot`',
            if (stillLocked) _stillLocked,
            if (backMissed)
              'the back gesture changed nothing after two tries: there may be '
                  'no route to pop, or a PopScope refused',
          ],
          nextSteps: [
            if (stillLocked)
              'hardware_button unlock once more; if it stays locked, '
                  '`device op:screenshot` shows what the lock screen is waiting for'
            else if (button == HardwareButton.unlock && lifecycle != 'resumed')
              'the app is still $lifecycle: wait a moment, then get_scene; '
                  'if it stays paused, `hardware_button home` and reopen it'
            else if (button == HardwareButton.unlock)
              'call get_scene to read the screen after unlock'
            else if (button == HardwareButton.home && !stuck)
              'the app is now backgrounded: reopen it then call get_scene'
            else if (button == HardwareButton.lock && !stuck)
              'device is locked: call hardware_button with unlock to resume'
            else if (backMissed)
              'get_scene to see where you are; if a dialog is up, dismiss it first'
            else if (button == HardwareButton.back)
              'call get_scene to read the screen you went back to',
          ],
        );
      }
      return response;
    } finally {
      await scene.dispose();
    }
  }

  /// A back gesture is a route change or nothing: read `changed` like a tap does, and give the gesture one more try when the first missed.
  Future<StructuredResponse> _backOutcome(GlintSession session, Scene scene,
      StructuredResponse response, SceneSnapshot? pre) async {
    var post = await readPostActionState(session, pre, includeSceneText: false);
    if (post != null && !post.changed) {
      final again = StructuredResponse.fromActionResult(await session.interactor
          .run(scene, PressHardwareButton(HardwareButton.back)));
      if (again.isError) return again;
      post = await readPostActionState(session, pre, includeSceneText: false);
    }
    return post == null ? response : response.mergeData(post.toData());
  }

  static const _stillLocked =
      'the device still reports itself locked after the unlock sequence';

  /// SpringBoard's lock state after a lock / unlock press; null for other buttons or when the backend cannot tell.
  Future<bool?> _lockStateFor(GlintSession session, HardwareButton button) async {
    if (button != HardwareButton.lock && button != HardwareButton.unlock) {
      return null;
    }
    try {
      return await session.backend.lockState();
    } on Object {
      return null;
    }
  }

  /// The lifecycle after the press has taken effect: polls up to ~1.5s for a
  /// change away from (or back to) resumed, so the reply reports the outcome
  /// rather than the state a few ms after the press. A read that gets no
  /// answer within a second means the OS suspended the app.
  Future<String?> _settledLifecycle(
      GlintSession session, HardwareButton button) async {
    final wantsResumed = button == HardwareButton.unlock;
    final expectsChange = button != HardwareButton.back;
    String? last;
    for (var i = 0; i < (expectsChange ? 6 : 1); i++) {
      try {
        last = await session
            .lifecycleState()
            .timeout(const Duration(seconds: 1));
      } on TimeoutException {
        return wantsResumed ? last : 'suspended';
      } on Object {
        return last;
      }
      if (wantsResumed ? last == 'resumed' : last != 'resumed') return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last;
  }
}
