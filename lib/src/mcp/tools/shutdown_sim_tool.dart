import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `shutdown_sim` — shut down a simulator/emulator, or all booted ones.
class ShutdownSimTool extends GlintTool {
  const ShutdownSimTool();

  @override
  Tool get definition => Tool(
        name: 'shutdown_sim',
        description:
            'Shut down a simulator/emulator. device: the one to stop (defaults '
            'to the attached device). all:true shuts down every booted device. '
            'Detaches first if glint is driving the device. iOS via simctl, '
            'Android via adb emu kill.',
        inputSchema: ObjectSchema(
          properties: {
            'device': Schema.string(
              description: 'Device id. Defaults to the attached device.',
            ),
            'all': Schema.bool(
              description: 'Shut down every booted device. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final all = (args['all'] as bool?) ?? false;
    final adbPath = session.isAttached && session.device is AndroidDevice
        ? (session.device as AndroidDevice).adbPath
        : 'adb';
    const launcher = AppLauncher();
    final scan = await DeviceDiscovery(adbPath: adbPath).scan();

    if (all) {
      if (scan.devices.isEmpty) {
        return StructuredResponse(
          summary: 'no booted devices',
          data: const {'shutDown': []},
        );
      }
      final done = <String>[];
      for (final d in scan.devices) {
        final err = await launcher.shutdown(d.platform, d.id, adbPath: adbPath);
        done.add(err == null ? d.id : '${d.id} (failed: $err)');
      }
      if (session.isAttached) await session.detach();
      return StructuredResponse(
        summary: 'shut down ${scan.devices.length} device(s)',
        data: {'shutDown': done},
      );
    }

    final deviceArg = args['device'] as String?;
    final deviceId =
        deviceArg ?? (session.isAttached ? session.device.id : null);
    if (deviceId == null) {
      return StructuredResponse.error(
        summary: 'no device — pass device, all:true, or attach first',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass device:"<udid/serial>" or all:true'],
      );
    }
    final platform = _platformOf(deviceId, scan, session);
    final isThisDevice = session.isAttached && session.device.id == deviceId;
    if (isThisDevice) await session.detach();

    final err = await launcher.shutdown(platform, deviceId, adbPath: adbPath);
    if (err != null) {
      return StructuredResponse.error(
        summary: 'could not shut down $deviceId',
        errorKind: GlintErrorKind.backendToolError,
        detail: err,
      );
    }
    return StructuredResponse(
      summary: 'shut down $deviceId',
      data: {'device': deviceId, if (isThisDevice) 'detached': true},
    );
  }

  // Booted scan first; else the attached device; else infer from the id shape
  // (an iOS UDID is 36-char hyphenated hex).
  DevicePlatform _platformOf(
      String id, DiscoveryResult scan, GlintSession session) {
    for (final d in scan.devices) {
      if (d.id == id) return d.platform;
    }
    if (session.isAttached && session.device.id == id) {
      return session.device is IosSimulator
          ? DevicePlatform.ios
          : DevicePlatform.android;
    }
    return id.length == 36 && id.contains('-')
        ? DevicePlatform.ios
        : DevicePlatform.android;
  }
}
