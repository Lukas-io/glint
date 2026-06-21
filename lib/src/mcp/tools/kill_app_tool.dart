import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `kill_app` — stop a running app glint started (or the attached one) and detach.
class KillAppTool extends GlintTool {
  const KillAppTool();

  @override
  Tool get definition => Tool(
        name: 'kill_app',
        description:
            'Stop a running Flutter app and detach. With no args, stops the '
            'app glint launched / is attached to. A glint-launched app is '
            'stopped via its `flutter run`; an attached app is also terminated '
            'on the device when its bundle id is known. '
            'device: target device (defaults to the attached one). '
            'appId: bundle id (iOS) or package (Android) to force-terminate.',
        inputSchema: ObjectSchema(
          properties: {
            'device': Schema.string(
              description: 'Device id. Defaults to the attached device.',
            ),
            'appId': Schema.string(
              description: 'Bundle id (iOS) / package (Android) to terminate.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final deviceArg = args['device'] as String?;
    final attached = session.isAttached;
    final deviceId = deviceArg ?? (attached ? session.device.id : null);
    if (deviceId == null) {
      return StructuredResponse.error(
        summary: 'no device to stop — attach first, or pass device',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass device:"<udid/serial>"'],
      );
    }
    final isThisDevice = attached && session.device.id == deviceId;
    final platform = isThisDevice
        ? (session.device is IosSimulator
            ? DevicePlatform.ios
            : DevicePlatform.android)
        : null;
    final adbPath = isThisDevice && session.device is AndroidDevice
        ? (session.device as AndroidDevice).adbPath
        : 'adb';

    final done = <String>[];

    // 1. A glint-launched app stops cleanly via its flutter run process.
    final proc = session.launchedAppFor(deviceId);
    if (proc != null) {
      proc.kill();
      session.clearLaunchedApp(deviceId);
      done.add('stopped flutter run');
    }

    // 2. Terminate on device when we know the app id and platform.
    final appId = (args['appId'] as String?) ??
        (isThisDevice ? session.attachedBundleId : null);
    if (platform != null && appId != null) {
      final err = await const AppLauncher()
          .terminateApp(platform, deviceId, appId, adbPath: adbPath);
      done.add(err == null ? 'terminated $appId' : 'terminate failed: $err');
    }

    // 3. Detach when we were driving this device.
    if (isThisDevice) {
      await session.detach();
      done.add('detached');
    }

    if (done.isEmpty) {
      return StructuredResponse.error(
        summary: 'nothing to stop on $deviceId',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'no glint-launched app for this device and no appId to '
            'terminate',
        nextSteps: const [
          'pass appId:"<bundleId/package>" to force-stop it on the device',
        ],
      );
    }
    return StructuredResponse(
      summary: 'killed app on $deviceId: ${done.join(", ")}',
      data: {'device': deviceId, 'actions': done},
    );
  }
}
