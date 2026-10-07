import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

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
            'appId: bundle id (iOS) or package (Android) to force-terminate; '
            'an app this session never attached is refused unless force:true.',
        inputSchema: ObjectSchema(
          properties: {
            'device': Schema.string(
              description: 'Device id. Defaults to the attached device.',
            ),
            'appId': Schema.string(
              description: 'Bundle id (iOS) / package (Android) to terminate.',
            ),
            'force': Schema.bool(
              description: 'Terminate an appId this session did not attach. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final deviceArg = args['device'] as String?;
    final deviceId = deviceArg ?? session.active?.id;
    if (deviceId == null) {
      return StructuredResponse.error(
        summary: 'no device to stop — attach first, or pass device',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass device:"<udid/serial>"'],
      );
    }
    final requestedAppId = args['appId'] as String?;
    final force = argBool(args, 'force') ?? false;
    if (requestedAppId != null && !force && !session.ownsApp(requestedAppId)) {
      return StructuredResponse.error(
        summary: 'refused: $requestedAppId is not an app this session attached or launched',
        errorKind: GlintErrorKind.notOwned,
        detail: 'it may belong to another project or agent working on $deviceId',
        nextSteps: const [
          'call kill_app with no appId to stop the app you are driving',
          'only if the user asked to stop that app: pass force:true',
        ],
      );
    }
    final pooled = session.appFor(deviceId);
    final isThisDevice = pooled != null;
    final platform = pooled?.platform;
    final pooledDevice = pooled?.device;
    final adbPath = pooledDevice is AndroidDevice
        ? pooledDevice.adbPath
        : resolveAdbPath(null) ?? 'adb';

    final done = <String>[];

    // 1. A glint-launched app stops cleanly via its flutter run process.
    final proc = session.launchedAppFor(deviceId);
    if (proc != null) {
      proc.kill();
      session.clearLaunchedApp(deviceId);
      done.add('stopped flutter run');
    }

    // 2. Terminate on device when we know the app id and platform.
    final appId = requestedAppId ?? pooled?.bundleId;
    if (platform != null && appId != null) {
      final err = await const AppLauncher()
          .terminateApp(platform, deviceId, appId, adbPath: adbPath);
      done.add(err == null ? 'terminated $appId' : 'terminate failed: $err');
    }

    // 3. Detach when we were driving this device.
    if (isThisDevice) {
      await session.detach(deviceId: deviceId);
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
