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
            'mode: flutter | device | auto (default). device mode drives the '
            'simulator with NO Flutter app — perception via device '
            'op:screenshot, interaction via x,y coordinate taps. auto picks '
            'device mode when no running app is found. '
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
            'mode': Schema.string(
              description:
                  'flutter | device | auto (default). device = drive the sim '
                  'with no Flutter app.',
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

    final mode = args['mode'] as String?;
    if (mode != null &&
        !const {'flutter', 'device', 'auto'}.contains(mode)) {
      return StructuredResponse.error(
        summary: 'unknown mode: $mode',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use one of: flutter, device, auto'],
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

    // ── Device mode: explicit, or auto when no app is discovered ────────────
    final vmUriArg = args['vmUri'] as String?;
    if (mode == 'device') {
      return _attachDeviceMode(session, scan, args, platformArg, adbPath);
    }

    // ── 1. Resolve the VM service URI (discover if absent) ──────────────────
    final Uri vmUri;
    if (vmUriArg != null) {
      vmUri = Uri.parse(vmUriArg);
    } else {
      if (scan.vmUris.isEmpty) {
        // No Flutter app found. Unless flutter mode was forced, fall back to
        // driving the device directly.
        if (mode != 'flutter') {
          return _attachDeviceMode(session, scan, args, platformArg, adbPath);
        }
        return StructuredResponse.error(
          summary: 'no running Flutter app found to attach to',
          errorKind: GlintErrorKind.targetNotFound,
          detail: scan.devices.isEmpty
              ? 'no booted simulators/emulators detected either'
              : 'booted devices: ${scan.devices.map((d) => d.name).join(", ")}',
          nextSteps: const [
            'start a Flutter app in debug mode (flutter run), then call attach',
            'or attach in device mode (mode:"device") to drive the sim directly',
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
      final simStatus = platform == DevicePlatform.ios
          ? await const SimControl().status(deviceId)
          : null;
      final deviceName = simStatus?.name ?? info?.name;
      final osVersion = simStatus?.osVersion ?? info?.osVersion;
      // Prefer the Dart package name (distinguishes apps) over the iOS bundle
      // name, which is almost always the generic "Runner".
      final appName = _packageName(probe.rootLibraryUri) ?? link?.appName;

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
        if (simStatus?.appearance != null)
          'appearance': simStatus!.appearance
        else if (ui.brightness != null)
          'appearance': ui.brightness,
        if (simStatus?.contentSize != null) 'textSize': simStatus!.contentSize,
        if (ui.locale != null) 'locale': ui.locale,
        if (ui.keyboardBottomPx > 0) 'keyboardVisible': true,
      };

      return StructuredResponse(
        summary: 'attached to ${deviceName ?? platform.name} ($deviceId)'
            '${appName != null ? " running $appName" : ""} '
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
          if (deviceName != null) 'deviceName': deviceName,
          if (osVersion != null) 'osVersion': osVersion,
          if (simStatus?.deviceType != null) 'deviceType': simStatus!.deviceType,
          if (simStatus?.state != null) 'state': simStatus!.state,
          if (appName != null) 'app': appName,
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

  /// Bind a device with no Flutter app. Perception is via `device
  /// op:screenshot`; interaction via x,y coordinate taps. For iOS the device is
  /// sized to the screenshot pixels with dpr=1, so `tap = pixel / screenshotSize`.
  Future<StructuredResponse> _attachDeviceMode(
    GlintSession session,
    DiscoveryResult scan,
    Map<String, Object?> args,
    String? platformArg,
    String adbPath,
  ) async {
    // Resolve the target device.
    final deviceArg = args['device'] as String?;
    BootedDevice? target;
    if (deviceArg != null) {
      for (final d in scan.devices) {
        if (d.id == deviceArg) {
          target = d;
          break;
        }
      }
      if (target == null) {
        final p = _platformFromArg(platformArg);
        if (p == null) {
          return StructuredResponse.error(
            summary: 'device $deviceArg is not booted and platform is unknown',
            errorKind: GlintErrorKind.invalidArgument,
            nextSteps: const [
              'boot the device, or pass platform: ios | android',
            ],
          );
        }
        target = BootedDevice(platform: p, id: deviceArg, name: deviceArg);
      }
    } else {
      final platform = _platformFromArg(platformArg);
      final candidates =
          platform != null ? scan.devicesFor(platform) : scan.devices;
      if (candidates.isEmpty) {
        return StructuredResponse.error(
          summary: 'no booted device to attach to',
          errorKind: GlintErrorKind.targetNotFound,
          nextSteps: const ['boot a simulator/emulator, then call attach'],
        );
      }
      if (candidates.length > 1) {
        return _selection(
          'multiple booted devices — re-call attach with one device',
          scan,
        );
      }
      target = candidates.single;
    }

    // Size the device from a screenshot — also the coordinate reference.
    final shotPath =
        '${Directory.systemTemp.path}/glint-attach-${target.id}.png';
    final shot = await _probeScreenSize(target, adbPath, shotPath);
    final screen = (shot.width != null && shot.height != null)
        ? {'width': shot.width, 'height': shot.height, 'unit': 'screenshot-pixels'}
        : null;

    final warnings = <String>[];
    final DeviceTarget device;
    switch (target.platform) {
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
        // iOS taps inject a ratio of the size, so the size is required.
        if (screen == null) {
          return StructuredResponse.error(
            summary: 'could not capture the screen to size device ${target.id}',
            errorKind: GlintErrorKind.backendToolError,
            detail: shot.error,
          );
        }
        device = IosSimulator(
          udid: target.id,
          logicalWidth: shot.width!.toDouble(),
          logicalHeight: shot.height!.toDouble(),
          devicePixelRatio: 1.0,
          bridgePath: bridgePath,
        );
      case DevicePlatform.android:
        // Android taps take raw pixels; the size only enables center scroll.
        if (screen == null && shot.error != null) {
          warnings.add('could not size the screen: ${shot.error}');
        }
        device = AndroidDevice(
          serial: target.id,
          adbPath: adbPath,
          screenWidth: shot.width?.toDouble(),
          screenHeight: shot.height?.toDouble(),
        );
    }

    await session.attachDevice(device: device);

    final caps = session.backend.capabilities;
    final simStatus = target.platform == DevicePlatform.ios
        ? await const SimControl().status(target.id)
        : null;

    return StructuredResponse(
      summary: 'attached (device mode) to ${simStatus?.name ?? target.name} '
          '(${target.id}) — no Flutter app; drive via screenshot + coordinates',
      warnings: warnings,
      nextSteps: const [
        'call `device op:screenshot` to see the screen',
        'tap / swipe with x,y in screenshot pixels',
      ],
      data: {
        'platform': target.platform.name,
        'device': target.id,
        'deviceName': simStatus?.name ?? target.name,
        if (simStatus?.osVersion != null) 'osVersion': simStatus!.osVersion,
        if (simStatus?.deviceType != null) 'deviceType': simStatus!.deviceType,
        if (simStatus?.state != null) 'state': simStatus!.state,
        if (simStatus?.appearance != null) 'appearance': simStatus!.appearance,
        'mode': 'device',
        'hardwareButtons': [for (final b in caps.hardwareButtons) b.name],
        if (screen != null) 'screen': screen,
      },
    );
  }

  /// Screenshot just to read the screen size. iOS goes through simctl (the
  /// IosSimulator can't be built before its size is known); Android through the
  /// adb backend.
  Future<ScreenshotResult> _probeScreenSize(
      BootedDevice target, String adbPath, String path) {
    return target.platform == DevicePlatform.ios
        ? const SimControl().screenshot(target.id, path)
        : AndroidDevice(serial: target.id, adbPath: adbPath)
            .createBackend()
            .screenshot(path);
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

  /// `package:aetrust/main.dart` → `aetrust`. Null for non-package URIs.
  String? _packageName(String? rootLibUri) {
    final u = rootLibUri == null ? null : Uri.tryParse(rootLibUri);
    return (u?.scheme == 'package' && u!.pathSegments.isNotEmpty)
        ? u.pathSegments.first
        : null;
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
