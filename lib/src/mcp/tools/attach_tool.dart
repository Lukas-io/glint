import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../../../runtime.dart';
import '../../../semantic.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

const String _kDefaultBridgePath =
    'native/ios_sim_bridge/.build/debug/glint-iossim';

/// `attach` — connect to a Flutter app's VM and bind the device it's actually
/// running on. Every argument is optional: glint discovers the app, derives the
/// platform from the VM, correlates the app to its real simulator (so it picks
/// the right one even with several booted), and reports device + app identity,
/// capabilities, and screen context in one reply.
class AttachTool extends GlintTool {
  const AttachTool();

  @override
  Tool get definition => Tool(
        name: 'attach',
        description:
            'Connect glint to a running Flutter debug app. Must be called once '
            'before any other tool. ALL ARGS OPTIONAL — call with no args and '
            'glint discovers the app, derives platform from the VM, and '
            'correlates the app to the exact simulator it runs on (correct even '
            'with multiple sims booted). '
            'vmUri: VM service URI (http:// or ws://) — omit to auto-discover. '
            'platform: ios | android — omit to derive from the VM. '
            'device: UDID / serial — omit to auto-correlate; if you pass one '
            'that does not host the app, attach refuses (taps would hit the '
            'wrong device). '
            'returnScene: include the first get_scene render. dryRun: list '
            'attachable apps + devices without attaching. awaitSettle: wait for '
            'the UI to settle first. '
            'Returns platform, device + app identity, hardwareButtons available, '
            'and screen (viewport, dpr, orientation, brightness, locale). '
            'errorKind: targetNotFound (no app / no device), invalidArgument '
            '(device/app mismatch), internal (VM unreachable). '
            'Companion: flutter-network__network_attach takes the same vmUri for '
            'logs + HTTP monitoring (separate connection, no conflict).',
        inputSchema: ObjectSchema(
          properties: {
            'vmUri': Schema.string(
              description:
                  'VM service URI, e.g. ws://127.0.0.1:1234/abc=/ws. Omit to '
                  'auto-discover the running app.',
            ),
            'platform': Schema.string(
              description: 'ios | android. Omit to derive from the VM.',
            ),
            'device': Schema.string(
              description:
                  'iOS simulator UDID or Android serial. Omit to auto-correlate '
                  'to the app\'s real device.',
            ),
            'iosBridgePath': Schema.string(
              description: 'Path to compiled `glint-iossim` binary. iOS only.',
            ),
            'adbPath': Schema.string(
              description: 'adb executable path. Android only.',
            ),
            'returnScene': Schema.bool(
              description: 'Include the first get_scene render. Default false.',
            ),
            'dryRun': Schema.bool(
              description:
                  'List attachable apps + devices without attaching. '
                  'Default false.',
            ),
            'awaitSettle': Schema.bool(
              description:
                  'Wait until the UI settles before returning. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};

    // Validate an explicitly-passed platform before any I/O.
    final platformArg = args['platform'] as String?;
    if (platformArg != null &&
        !const {'ios', 'android'}.contains(platformArg)) {
      return StructuredResponse.error(
        summary: 'unknown platform: $platformArg',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: ios, android'],
      );
    }

    final adbPath = (args['adbPath'] as String?) ?? 'adb';
    final returnScene = (args['returnScene'] as bool?) ?? false;
    final dryRun = (args['dryRun'] as bool?) ?? false;
    final awaitSettle = (args['awaitSettle'] as bool?) ?? false;
    final discovery = DeviceDiscovery(adbPath: adbPath);

    // One scan powers discovery + identity + the correlation fallback.
    final scan = await discovery.scan();

    // ── dryRun: list what's attachable and stop ─────────────────────────────
    if (dryRun) {
      return StructuredResponse(
        summary: _dryRunSummary(scan),
        data: {
          'dryRun': true,
          'apps': [for (final u in scan.vmUris) u.toString()],
          'devices': [for (final d in scan.devices) d.toJson()],
        },
      );
    }

    // ── 1. Resolve the VM service URI (discover if absent) ──────────────────
    final vmUriArg = args['vmUri'] as String?;
    final Uri vmUri;
    if (vmUriArg != null) {
      vmUri = Uri.parse(vmUriArg);
    } else {
      if (scan.vmUris.isEmpty) {
        return StructuredResponse.error(
          summary: 'no running Flutter app found to attach to',
          errorKind: GlintErrorKind.targetNotFound,
          detail: scan.devices.isEmpty
              ? 'no booted simulators/emulators detected either'
              : 'booted devices: ${scan.devices.map((d) => d.name).join(", ")}',
          nextSteps: const [
            'start a Flutter app in debug mode (flutter run), then call attach',
            'or pass vmUri explicitly if you already have the VM service URI',
          ],
        );
      }
      if (scan.vmUris.length > 1) {
        return _selection(
          'multiple running Flutter apps found — re-call attach with one vmUri',
          scan,
        );
      }
      vmUri = scan.vmUris.single;
    }

    // ── 2. Connect a probe runtime to read platform + viewport ──────────────
    final probe = VmServiceRuntime();
    try {
      await probe.attach(vmUri);
    } on Object catch (e) {
      return StructuredResponse.error(
        summary: 'could not connect to VM service at $vmUri',
        errorKind: GlintErrorKind.internal,
        detail: '$e',
        nextSteps: const [
          'confirm the app is running in debug mode',
          'the vmUri changes on each app restart — re-discover by calling '
              'attach with no vmUri',
        ],
      );
    }

    try {
      // ── 3. Read the VM once: platform + Dart version ──────────────────────
      final vm = await probe.rawService.getVM();
      final platform =
          _platformFromArg(platformArg) ?? _platformFromOs(vm.operatingSystem);
      if (platform == null) {
        return StructuredResponse.error(
          summary: 'could not determine platform from the VM '
              '(operatingSystem: ${vm.operatingSystem ?? "unknown"})',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['pass platform explicitly: ios | android'],
        );
      }

      // ── 4. Correlate the app to the device it's actually running on ────────
      final link = await discovery.correlate(vmUri, platform);

      // ── 5. Resolve the device id ──────────────────────────────────────────
      final deviceArg = args['device'] as String?;
      final String deviceId;
      if (deviceArg != null) {
        if (link != null && link.deviceId != deviceArg) {
          return StructuredResponse.error(
            summary: 'device $deviceArg does not host this app',
            errorKind: GlintErrorKind.invalidArgument,
            detail: 'the app at $vmUri runs on ${link.deviceId}'
                '${link.appName != null ? " (${link.appName})" : ""} — '
                'attaching to $deviceArg would send taps to the wrong device',
            nextSteps: [
              'omit device to auto-correlate',
              'or pass device: "${link.deviceId}"',
            ],
          );
        }
        deviceId = deviceArg;
      } else if (link != null) {
        deviceId = link.deviceId; // correct even with several sims booted
      } else {
        final candidates = scan.devicesFor(platform);
        if (candidates.isEmpty) {
          return StructuredResponse.error(
            summary: 'no booted ${platform.name} device found',
            errorKind: GlintErrorKind.targetNotFound,
            nextSteps: [
              'boot an ${platform.name} '
                  '${platform == DevicePlatform.ios ? "simulator" : "emulator"}, '
                  'then call attach',
              'or pass device explicitly',
            ],
          );
        }
        if (candidates.length > 1) {
          return _selection(
            'multiple booted ${platform.name} devices and the app could not be '
                'correlated — re-call attach with one device',
            scan,
          );
        }
        deviceId = candidates.single.id;
      }

      BootedDevice? info;
      for (final d in scan.devices) {
        if (d.id == deviceId) {
          info = d;
          break;
        }
      }

      // ── 6. Build the device target (+ iOS bridge preflight, viewport) ─────
      final warnings = <String>[];
      final DeviceTarget device;
      switch (platform) {
        case DevicePlatform.android:
          device = AndroidDevice(serial: deviceId, adbPath: adbPath);
        case DevicePlatform.ios:
          final bridgePath =
              (args['iosBridgePath'] as String?) ?? _kDefaultBridgePath;
          if (!File(bridgePath).existsSync()) {
            warnings.add(
              'glint-iossim bridge not found at $bridgePath — tap / swipe / '
              'long_press / type will fail until it is built '
              '(cd native/ios_sim_bridge && swift build), or pass iosBridgePath',
            );
          }
          final timeoutMs = session.config.attachProbeTimeoutMs;
          final vp = await _probeViewportWithRetry(probe, timeoutMs);
          if (vp == null) {
            return StructuredResponse.error(
              summary: 'attached to the VM but could not probe the iOS viewport',
              errorKind: GlintErrorKind.targetNotFound,
              detail: 'no addressable node rendered within ${timeoutMs}ms — '
                  'the app may be stuck on a blank/loading frame',
              nextSteps: const [
                'wait for the first screen to render, then call attach again',
                'raise the ceiling for slow launches: '
                    'config set attachProbeTimeoutMs <ms>',
              ],
            );
          }
          device = IosSimulator(
            udid: deviceId,
            logicalWidth: vp.w,
            logicalHeight: vp.h,
            devicePixelRatio: vp.dpr,
            bridgePath: bridgePath,
          );
      }

      // ── 7. Hand the resolved target to the session ────────────────────────
      await session.attach(vmUri: vmUri, device: device);

      // ── 8. Gather post-attach context ─────────────────────────────────────
      final caps = session.backend.capabilities;
      final ui = await session.uiState();
      final lifecycle = await session.lifecycleState();

      Map<String, Object?>? settleData;
      if (awaitSettle) {
        final r = await session.settleDetector.awaitSettle(
          ceilingMs: session.config.settleCeilingMs,
          quietFramesNeeded: session.config.settleQuietFrames,
        );
        settleData = {'settled': r is SettledOk, 'elapsedMs': r.elapsedMs};
      }

      String? sceneText;
      if (returnScene) sceneText = await _renderScene(session);

      // ── 9. Build the reply ────────────────────────────────────────────────
      final dartVersion = vm.version;
      final screen = <String, Object?>{
        if (device is IosSimulator) ...{
          'logicalWidth': device.logicalWidth,
          'logicalHeight': device.logicalHeight,
          'devicePixelRatio': device.devicePixelRatio,
        },
        if (ui.orientation != null) 'orientation': ui.orientation,
        if (ui.brightness != null) 'brightness': ui.brightness,
        if (ui.locale != null) 'locale': ui.locale,
        if (ui.keyboardBottomPx > 0) 'keyboardVisible': true,
      };

      return StructuredResponse(
        summary: 'attached to ${info?.name ?? platform.name} ($deviceId)'
            '${link?.appName != null ? " running ${link!.appName}" : ""} '
            'at $vmUri',
        warnings: warnings,
        nextSteps: [
          'call flutter-network__network_attach vmServiceUri:"$vmUri" for app '
              'logs (flutter-network__logs_tail) + HTTP monitoring — same URI, '
              'separate connection, no conflict',
          if (!returnScene) 'call `get_scene` to read the current screen',
          'use `tap` / `swipe` / `type` / `hardware_button` to drive the app',
        ],
        data: {
          'platform': platform.name,
          'device': deviceId,
          if (info?.name != null) 'deviceName': info!.name,
          if (info?.osVersion != null) 'osVersion': info!.osVersion,
          if (link?.appName != null) 'app': link!.appName,
          'vmUri': vmUri.toString(),
          'mode': 'flutter',
          if (dartVersion != null && dartVersion.isNotEmpty)
            'dartVersion': dartVersion.split(' ').first,
          if (lifecycle != null) 'appState': lifecycle,
          'hardwareButtons': [for (final b in caps.hardwareButtons) b.name],
          'autoDetected': {
            'vmUri': vmUriArg == null,
            'platform': platformArg == null,
            'device': deviceArg == null,
            'correlated': link != null,
          },
          'screen': screen,
          if (settleData != null) 'settle': settleData,
          if (sceneText != null) 'scene': sceneText,
        },
      );
    } finally {
      await probe.disconnect();
    }
  }

  /// Probe the logical viewport, retrying past a blank first frame until
  /// [timeoutMs] elapses. Returns null if no addressable node ever appears —
  /// the caller turns that into a structured, recoverable response.
  Future<({double w, double h, double dpr})?> _probeViewportWithRetry(
    VmServiceRuntime probe,
    int timeoutMs, {
    Duration delay = const Duration(milliseconds: 250),
  }) async {
    final reader = SceneReader(InspectorClient(probe), probe);
    final resolver = CoordinateResolver(probe);
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    var first = true;
    while (first || DateTime.now().isBefore(deadline)) {
      first = false;
      final scene = await reader.readSummary();
      try {
        final probeId = scene.firstAddressableId();
        if (probeId != null) {
          final vp = await resolver.resolveViewport(scene, probeId);
          return (w: vp.w, h: vp.h, dpr: vp.dpr);
        }
      } finally {
        await scene.dispose();
      }
      if (DateTime.now().add(delay).isBefore(deadline)) {
        await Future<void>.delayed(delay);
      } else {
        break;
      }
    }
    return null;
  }

  Future<String> _renderScene(GlintSession session) async {
    final scene = await session.reader.readSummary();
    try {
      final semantic = session.semanticizer.semanticize(scene);
      await session.overlayEnricher.enrich(semantic);
      await session.inputEnricher.enrich(semantic);
      await session.iconEnricher.enrich(semantic);
      await session.navEnricher.enrich(semantic);
      return const PlainTextSceneRenderer().render(semantic);
    } finally {
      await scene.dispose();
    }
  }

  String _dryRunSummary(DiscoveryResult scan) {
    return [
      'apps (${scan.vmUris.length}):',
      for (final u in scan.vmUris) '  $u',
      'devices (${scan.devices.length}):',
      for (final d in scan.devices)
        '  ${d.id}  (${[
          d.name,
          if (d.osVersion != null) d.osVersion!,
          d.platform.name,
        ].join(", ")})',
    ].join('\n');
  }

  /// A "needs selection" reply: not an error, but glint can't pick for the
  /// agent. Lists the candidates so the agent re-calls with an explicit choice.
  StructuredResponse _selection(String summary, DiscoveryResult d) {
    return StructuredResponse(
      summary: summary,
      nextSteps: [
        for (final u in d.vmUris) 'vmUri: "$u"',
        for (final dev in d.devices)
          'device: "${dev.id}"  (${dev.name}, ${dev.platform.name})',
      ],
      data: {
        'needsSelection': true,
        'apps': [for (final u in d.vmUris) u.toString()],
        'devices': [for (final dev in d.devices) dev.toJson()],
      },
    );
  }

  DevicePlatform? _platformFromArg(String? arg) => switch (arg) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        _ => null,
      };

  DevicePlatform? _platformFromOs(String? os) => switch (os?.toLowerCase()) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        _ => null,
      };
}
