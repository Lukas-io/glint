import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `attach` — connect to a Flutter app's VM and bind a device. For iOS,
/// probes the live viewport + DPR so the agent doesn't have to.
class AttachTool extends GlintTool {
  const AttachTool();

  @override
  Tool get definition => Tool(
        name: 'attach',
        description:
            'Attach glint to a running Flutter app. Required before any other tool. '
            'Provide the VM service WebSocket URI plus the target platform and device id.',
        inputSchema: ObjectSchema(
          properties: {
            'vmUri': Schema.string(
              description:
                  'WebSocket VM service URI, e.g. ws://127.0.0.1:1234/abc=/ws',
            ),
            'platform': Schema.string(
              description: 'Target platform. One of: ios, android',
            ),
            'device': Schema.string(
              description:
                  'iOS simulator UDID, or Android emulator/device serial (`adb devices`).',
            ),
            'iosBridgePath': Schema.string(
              description:
                  'Path to compiled `glint-iossim` binary. iOS only.',
            ),
            'adbPath': Schema.string(
              description: 'adb executable path. Android only.',
            ),
          },
          required: ['vmUri', 'platform', 'device'],
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final vmUri = Uri.parse(args['vmUri']! as String);
    final platform = args['platform']! as String;
    final deviceId = args['device']! as String;

    final DeviceTarget device;
    switch (platform) {
      case 'android':
        device = AndroidDevice(
          serial: deviceId,
          adbPath: (args['adbPath'] as String?) ?? 'adb',
        );
      case 'ios':
        final bridgePath = (args['iosBridgePath'] as String?) ??
            'native/ios_sim_bridge/.build/debug/glint-iossim';
        device = await _probeIosTarget(
          vmUri: vmUri,
          udid: deviceId,
          bridgePath: bridgePath,
        );
      default:
        return StructuredResponse.error(
          summary: 'unknown platform: $platform',
          errorKind: 'InvalidArgument',
          nextSteps: const ['use one of: ios, android'],
        );
    }

    await session.attach(vmUri: vmUri, device: device);

    return StructuredResponse(
      summary: 'attached to $platform device $deviceId at $vmUri',
      nextSteps: const [
        'call `get_scene` to read the current screen',
        'use `tap` / `swipe` / `type` / `hardware_button` to drive the app',
      ],
      data: {
        'platform': platform,
        'device': deviceId,
        if (device is IosSimulator) ...{
          'logicalWidth': device.logicalWidth,
          'logicalHeight': device.logicalHeight,
          'devicePixelRatio': device.devicePixelRatio,
        },
      },
    );
  }

  Future<IosSimulator> _probeIosTarget({
    required Uri vmUri,
    required String udid,
    required String bridgePath,
  }) async {
    final probeVm = VmClient();
    await probeVm.attach(vmUri);
    try {
      final reader = SceneReader(InspectorClient(probeVm));
      final resolver = CoordinateResolver(probeVm);
      final scene = await reader.readSummary();
      try {
        final probeId = _firstAddressableId(scene.root);
        if (probeId == null) {
          throw StateError(
              'could not find an addressable node in the scene to probe iOS viewport');
        }
        final coord = await resolver.resolve(scene, probeId);
        return IosSimulator(
          udid: udid,
          logicalWidth: coord.logicalViewSize.w,
          logicalHeight: coord.logicalViewSize.h,
          devicePixelRatio: coord.devicePixelRatio,
          bridgePath: bridgePath,
        );
      } finally {
        await scene.dispose();
      }
    } finally {
      await probeVm.disconnect();
    }
  }

  String? _firstAddressableId(SceneNode n) {
    for (final c in n.walk()) {
      final id = c.glintId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }
}
