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

/// Resolves the glint-iossim bridge: explicit arg, then the copy inside glint's
/// own package tree (the MCP server's CWD is the host app's dir, not glint's),
/// then the legacy CWD-relative default.
String _resolveIosBridgePath(String? explicit) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return _bridgeUnderGlintRoot() ?? _kDefaultBridgePath;
}

/// Walks up from the running script to find the bridge under glint's package.
String? _bridgeUnderGlintRoot() {
  Directory dir;
  try {
    dir = File(Platform.script.toFilePath()).parent;
  } catch (_) {
    return null;
  }
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}/$_kDefaultBridgePath');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// `attach` — connect to a Flutter app's VM and bind the device it's actually
/// running on. Every argument is optional: glint discovers the app, derives the
/// platform from the VM, correlates the app to its real simulator (so it picks
/// the right one even with several booted), and reports device + app identity,
/// capabilities, and screen context in one reply.
class AttachTool extends GlintTool {
  const AttachTool();

  /// `app` here means "which app to attach/switch to", not call routing.
  @override
  bool get routesByApp => false;

  @override
  Tool get definition => Tool(
        name: 'attach',
        description:
            'Connect glint to a running Flutter debug app. Call once before any '
            'other tool. ALL ARGS OPTIONAL: with no args glint discovers the '
            'app, derives the platform from the VM, and correlates it to the '
            'exact simulator it runs on (correct even with several booted). A '
            '`device` that does not host the app is refused (taps would hit the '
            'wrong one). When nothing is running it does not error — it reports '
            '"no app running" and lists prior launches to start from. The reply '
            'carries device + app identity, available hardwareButtons, and '
            'screen (viewport, dpr, orientation, locale). Apps stay attached: '
            'attaching a second app pools it, and re-attaching a pooled app '
            '(by `app` or `device`) switches instantly with no probe.',
        inputSchema: ObjectSchema(
          properties: {
            'app': Schema.string(
              description:
                  'App to attach or switch to: display name, package, bundle '
                  'id, or the simulator name it runs on. Matches running apps '
                  'and already-attached ones.',
            ),
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
                  'to the app\'s real device. When nothing is running, passing a '
                  'device from the "no app running" list starts its app there.',
            ),
            'launch': Schema.string(
              description:
                  'Path to a Flutter project root to run when it is not in '
                  'history. Usually you pass a device from the no-app-running '
                  'list instead.',
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

    final adbResolved = resolveAdbPath(args['adbPath'] as String?);
    final adbPath = adbResolved ?? 'adb';
    if (adbResolved == null && platformArg == 'android') {
      return _adbMissing();
    }
    final returnScene = (args['returnScene'] as bool?) ?? false;
    final dryRun = (args['dryRun'] as bool?) ?? false;
    final awaitSettle = (args['awaitSettle'] as bool?) ?? false;
    final discovery = DeviceDiscovery(adbPath: adbPath);

    // One scan powers discovery + identity + the correlation fallback.
    final scan = await discovery.scan();

    // ── dryRun: list what's attachable + launch history and stop ────────────
    if (dryRun) {
      return StructuredResponse(
        summary: _dryRunSummary(scan, session.attachHistory.load()),
        data: {
          'dryRun': true,
          'apps': [for (final u in scan.vmUris) u.toString()],
          'devices': [for (final d in scan.devices) d.toJson()],
          'history': [for (final r in session.attachHistory.load()) r.toJson()],
        },
      );
    }

    final vmUriArg = args['vmUri'] as String?;
    final launchPath = (args['launch'] as String?)?.trim();
    final deviceArg = args['device'] as String?;
    final appArg = (args['app'] as String?)?.trim();

    // Progress sink for slow work (boot, flutter run) — emits a phase every 15s
    // when the client supplied a progress token.
    final onProgress = _progressSink(session, request);

    // ── 0. Instant switch to an app that is already attached ───────────────
    if (vmUriArg == null && launchPath == null) {
      final key = appArg ?? deviceArg;
      final pooled = key == null ? null : session.findApp(key);
      if (pooled != null &&
          pooled.isLive &&
          (mode == null || mode == 'auto' || (mode == 'device') == pooled.deviceMode)) {
        session.activate(pooled);
        return _switched(session, pooled, returnScene: returnScene);
      }
    }

    // ── Device mode: explicit ───────────────────────────────────────────────
    if (mode == 'device') {
      return _attachDeviceMode(session, scan, args, platformArg, adbPath, onProgress);
    }

    // ── 1. Resolve the VM service URI: explicit project path, arg, discovery,
    //       a device-selected relaunch, or — nothing running — the offer.
    final Uri vmUri;
    // Set when we launched — pins device resolution past the stale pre-launch scan.
    String? launchedDeviceId;
    if (launchPath != null && launchPath.isNotEmpty) {
      final r = await _launchPath(
          session, scan, launchPath, deviceArg, platformArg, onProgress);
      if (r.error != null) return r.error!;
      vmUri = r.vmUri!;
      launchedDeviceId = r.deviceId;
    } else if (vmUriArg != null) {
      vmUri = Uri.parse(vmUriArg);
    } else if (scan.vmUris.length == 1 && appArg == null && deviceArg == null) {
      vmUri = scan.vmUris.single;
    } else if (scan.vmUris.isNotEmpty) {
      final running = await discovery.describeRunningApps(scan);
      final picked = _pickRunning(running, appArg: appArg, deviceArg: deviceArg);
      if (picked.app == null) {
        return _selection(picked.reason!, scan, running: running, session: session);
      }
      vmUri = picked.app!.vmUri;
    } else if (deviceArg != null) {
      // Nothing running, but a specific device was selected — start its
      // remembered app on it.
      final rec = _historyForDevice(session, deviceArg);
      if (rec?.projectDir == null) {
        return _offerLaunch(session, scan,
            prefix: 'no app running on $deviceArg and no launchable history '
                'for it');
      }
      final platform = _platformFromName(rec!.platform) ??
          _platformFromArg(platformArg) ??
          DevicePlatform.ios;
      final r = await _launchProject(session,
          projectDir: rec.projectDir!,
          deviceId: deviceArg,
          platform: platform,
          onProgress: onProgress);
      if (r.error != null) return r.error!;
      vmUri = r.vmUri!;
      launchedDeviceId = deviceArg;
    } else {
      // Nothing running and no choice made — offer the history, don't dead-end.
      return _offerLaunch(session, scan);
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
      if (platform == DevicePlatform.android && adbResolved == null) {
        return _adbMissing();
      }
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
      // A just-launched device is treated like an explicit choice.
      final deviceArg = launchedDeviceId ?? (args['device'] as String?);
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
          // Probe the viewport for the real DPR — raw x,y gestures pass logical
          // points and adb takes physical pixels, so without the scale a
          // coordinate tap silently lands in the wrong place (glintId gestures
          // are unaffected: the resolver already yields physical px).
          final baseMs = session.config.attachProbeTimeoutMs;
          final timeoutMs = launchedDeviceId != null && baseMs < 30000
              ? 30000
              : baseMs;
          final probed =
              await _probeViewportWithRetry(probe, timeoutMs, onProgress);
          final vp = probed.viewport;
          if (vp == null) {
            warnings.add(
              'could not probe the Android viewport — raw x,y gestures may be '
              'mis-scaled; glintId gestures are unaffected'
              '${probed.lastError != null ? " (last probe error: ${probed.lastError})" : ""}',
            );
          }
          device = AndroidDevice(
            serial: deviceId,
            adbPath: adbPath,
            devicePixelRatio: vp?.dpr ?? 1.0,
          );
        case DevicePlatform.ios:
          final bridgePath =
              _resolveIosBridgePath(args['iosBridgePath'] as String?);
          if (!File(bridgePath).existsSync()) {
            warnings.add(
              'glint-iossim bridge not found at $bridgePath — tap / swipe / '
              'long_press / type will fail until it is built '
              '(cd native/ios_sim_bridge && swift build), or pass iosBridgePath',
            );
          }
          // A freshly launched app's inspector lags the VM URI by a few seconds;
          // an already-running app probes on the first try so the ceiling is free.
          final baseMs = session.config.attachProbeTimeoutMs;
          final timeoutMs = launchedDeviceId != null && baseMs < 30000
              ? 30000
              : baseMs;
          final probed =
              await _probeViewportWithRetry(probe, timeoutMs, onProgress);
          final vp = probed.viewport;
          if (vp == null) {
            return StructuredResponse.error(
              summary: 'attached to the VM but could not probe the iOS viewport',
              errorKind: GlintErrorKind.geometryResolveError,
              detail: 'no viewport probe succeeded within ${timeoutMs}ms'
                  '${probed.lastError != null ? " — last probe error: ${probed.lastError}" : " — no frame rendered yet"}',
              nextSteps: const [
                'wait for the first screen to render, then call attach again',
                'raise the ceiling for slow launches: '
                    'config set attachProbeTimeoutMs <ms>',
                'if the detail names an eval error, file it with '
                    '`report_issue` — attach should not need a specific root widget',
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
      // Project dir behind our VM (port→DDS-cwd correlation) — the anchor for
      // app identity and relaunch. Resolved before identity so bundle id/name
      // come from OUR built app, not a different app that also ran here.
      final projectDir = await discovery.projectDirForVm(vmUri);

      // App identity: package from the VM, plus display name / bundle id. Prefer
      // the project-correlated built app; fall back to a device scan only when
      // the project is unknown. Needed for kill_app's terminate.
      final package = _packageName(probe.rootLibraryUri);
      final iosInfo = platform == DevicePlatform.ios &&
              (link?.bundleId == null || link?.displayName == null)
          ? (projectDir != null
                  ? await discovery.appInfoForProject(projectDir)
                  : null) ??
              await discovery.appInfoForDevice(deviceId)
          : null;
      final bundleId = link?.bundleId ?? iosInfo?.$1;
      final displayName = link?.displayName ?? iosInfo?.$2;
      final appLabel = displayName ?? package ?? link?.appName;
      final app = <String, Object?>{
        if (package != null) 'package': package,
        if (displayName != null) 'name': displayName,
        if (bundleId != null) 'bundleId': bundleId,
      };
      session.active!
        ..package = package
        ..displayName = displayName
        ..bundleId = bundleId
        ..deviceName = deviceName;

      // Remember this attach so a future cold start can relaunch it.
      final appKey = package ?? _basename(projectDir) ?? link?.appName;
      if (appKey != null) {
        final now = DateTime.now();
        session.attachHistory.record(AttachRecord(
          appKey: appKey,
          displayName: displayName ?? package,
          bundleId: bundleId,
          deviceId: deviceId,
          platform: platform.name,
          deviceName: deviceName,
          osVersion: osVersion,
          projectDir: projectDir,
          firstSeen: now,
          lastSeen: now,
        ));
      }

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

      final others = session.apps.where((a) => a.id != deviceId).toList();
      return StructuredResponse(
        summary: 'attached to ${deviceName ?? platform.name} ($deviceId)'
            '${appLabel != null ? " running $appLabel" : ""} '
            'at $vmUri'
            '${others.isNotEmpty ? " · ${others.length} other app(s) still attached" : ""}',
        warnings: warnings,
        nextSteps: [
          if (!returnScene) 'call `get_scene` to read the current screen',
          'use `tap` / `swipe` / `type` / `hardware_button` to drive the app',
          if (others.isNotEmpty)
            'switch with attach app:"<name>", or target once with app:"<name>" '
                'on any tool: ${others.map((a) => '"${a.label}"').join(", ")}',
          'call flutter-network__network_attach vmServiceUri:"$vmUri" for HTTP '
              'monitoring — same URI, separate connection, no conflict',
        ],
        data: {
          'platform': platform.name,
          'device': deviceId,
          if (deviceName != null) 'deviceName': deviceName,
          if (osVersion != null) 'osVersion': osVersion,
          if (simStatus?.deviceType != null) 'deviceType': simStatus!.deviceType,
          if (simStatus?.state != null) 'state': simStatus!.state,
          if (app.isNotEmpty) 'app': app,
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
          'apps': session.appsJson(),
        },
      );
    } finally {
      await probe.disconnect();
    }
  }

  StructuredResponse _adbMissing() => StructuredResponse.error(
        summary: 'adb not found — cannot drive an Android emulator',
        errorKind: GlintErrorKind.invalidArgument,
        detail: 'looked on PATH, \$ANDROID_HOME, \$ANDROID_SDK_ROOT, '
            '~/Library/Android/sdk and ~/Android/Sdk',
        nextSteps: const [
          'pass adbPath:"<sdk>/platform-tools/adb"',
          'or set ANDROID_HOME so glint can find it',
        ],
      );

  /// Reply for an instant switch to an already-attached app.
  Future<StructuredResponse> _switched(GlintSession session, AppSession app,
      {required bool returnScene}) async {
    String? sceneText;
    if (returnScene && !app.deviceMode) {
      try {
        sceneText = await _renderScene(session);
      } on Object {
        sceneText = null;
      }
    }
    return StructuredResponse(
      summary: 'switched to ${app.label} on ${app.deviceName ?? app.id}'
          '${app.deviceMode ? " (device mode)" : ""}',
      nextSteps: [
        if (!returnScene && !app.deviceMode) 'call `get_scene` to read the current screen',
        if (app.deviceMode) 'call `device op:screenshot` to see the screen',
      ],
      data: {
        'switched': true,
        'platform': app.platform.name,
        'device': app.id,
        if (app.deviceName != null) 'deviceName': app.deviceName,
        if (!app.deviceMode)
          'app': {
            if (app.package != null) 'package': app.package,
            if (app.displayName != null) 'name': app.displayName,
            if (app.bundleId != null) 'bundleId': app.bundleId,
          },
        if (app.vmUri != null) 'vmUri': app.vmUri.toString(),
        'mode': app.deviceMode ? 'device' : 'flutter',
        if (sceneText != null) 'scene': sceneText,
        'apps': session.appsJson(),
      },
    );
  }

  /// Choose one running app from [running] by [appArg] / [deviceArg]; with
  /// neither, only an unambiguous single app is picked.
  ({RunningApp? app, String? reason}) _pickRunning(
    List<RunningApp> running, {
    String? appArg,
    String? deviceArg,
  }) {
    if (appArg != null) {
      final hits = running.where((r) => r.matches(appArg)).toList();
      if (hits.length == 1) return (app: hits.single, reason: null);
      return (
        app: null,
        reason: hits.isEmpty
            ? 'no running app matches app:"$appArg"'
            : 'app:"$appArg" matches ${hits.length} running apps — pick one',
      );
    }
    if (deviceArg != null) {
      final hits = running.where((r) => r.deviceId == deviceArg).toList();
      if (hits.length == 1) return (app: hits.single, reason: null);
      if (hits.isEmpty && running.length == 1) {
        return (app: running.single, reason: null);
      }
      return (
        app: null,
        reason: hits.isEmpty
            ? 'no running app could be correlated to device $deviceArg'
            : '${hits.length} running apps on $deviceArg — pick one by app',
      );
    }
    if (running.length == 1) return (app: running.single, reason: null);
    return (
      app: null,
      reason: 'multiple running Flutter apps found — re-call attach with app '
          'or device',
    );
  }

  /// Bind a device with no Flutter app — perception via screenshots, interaction via x,y (iOS sized to screenshot pixels, dpr=1).
  Future<StructuredResponse> _attachDeviceMode(
    GlintSession session,
    DiscoveryResult scan,
    Map<String, Object?> args,
    String? platformArg,
    String adbPath,
    void Function(int, String?)? onProgress,
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
        // Not booted — bring it up so we can drive it ("open the simulator").
        if (p == DevicePlatform.ios) {
          onProgress?.call(0, 'booting $deviceArg');
          final bootErr = await const AppLauncher().ensureBooted(p, deviceArg);
          if (bootErr != null) {
            return StructuredResponse.error(
              summary: 'could not boot device $deviceArg',
              errorKind: GlintErrorKind.backendToolError,
              detail: bootErr,
            );
          }
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
            _resolveIosBridgePath(args['iosBridgePath'] as String?);
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
  /// [timeoutMs]. The implicit view is asked first (no node needed); a
  /// selected node is the fallback. On failure the last error is kept so the
  /// agent sees the real reason instead of a guess.
  Future<({({double w, double h, double dpr})? viewport, Object? lastError})>
      _probeViewportWithRetry(
    VmServiceRuntime probe,
    int timeoutMs,
    void Function(int, String?)? onProgress, {
    Duration delay = const Duration(milliseconds: 250),
  }) async {
    final reader = SceneReader(InspectorClient(probe), probe);
    final resolver = CoordinateResolver(probe);
    final start = DateTime.now();
    final deadline = start.add(Duration(milliseconds: timeoutMs));
    var nextUpdate = start.add(const Duration(seconds: 15));
    var first = true;
    Object? lastError;
    while (first || DateTime.now().isBefore(deadline)) {
      first = false;
      try {
        final vp = await resolver.resolveViewportNodeFree();
        if (vp.w > 0 && vp.h > 0) {
          return (viewport: (w: vp.w, h: vp.h, dpr: vp.dpr), lastError: null);
        }
        lastError = 'implicit view reports a zero-sized viewport';
      } on Object catch (e) {
        lastError = e;
      }
      try {
        final scene = await reader.readSummary();
        try {
          final probeId = scene.firstAddressableId();
          if (probeId != null) {
            final vp = await resolver.resolveViewport(scene, probeId);
            return (
              viewport: (w: vp.w, h: vp.h, dpr: vp.dpr),
              lastError: null
            );
          }
          lastError = 'tree read ok but no addressable node yet';
        } finally {
          await scene.dispose();
        }
      } on Object catch (e) {
        // Inspector not ready yet — common in the first frames after a fresh
        // launch (getRootWidgetTree returns null). Keep retrying until deadline.
        lastError = e;
      }
      final now = DateTime.now();
      if (onProgress != null && now.isAfter(nextUpdate)) {
        onProgress(now.difference(start).inSeconds, 'waiting for first frame');
        nextUpdate = now.add(const Duration(seconds: 15));
      }
      if (now.add(delay).isBefore(deadline)) {
        await Future<void>.delayed(delay);
      } else {
        break;
      }
    }
    return (viewport: null, lastError: lastError);
  }

  Future<String> _renderScene(GlintSession session) =>
      session.withScene((s) async => const PlainTextSceneRenderer().render(s));

  String _dryRunSummary(DiscoveryResult scan, List<AttachRecord> history) {
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
      'history (${history.length}):',
      for (final r in history)
        '  ${r.label}  (${[
          r.deviceName ?? r.deviceId,
          if (r.launchable) 'launchable' else 'no projectDir',
          _ago(r.lastSeen),
        ].join(", ")})',
    ].join('\n');
  }

  /// Boot [deviceId], `flutter run` [projectDir] on it, track the process, and return its VM URI (or a ready error).
  Future<({Uri? vmUri, String? deviceId, StructuredResponse? error})>
      _launchProject(
    GlintSession session, {
    required String projectDir,
    required String deviceId,
    required DevicePlatform platform,
    void Function(int, String?)? onProgress,
  }) async {
    const launcher = AppLauncher();
    onProgress?.call(0, 'booting $deviceId');
    final bootErr = await launcher.ensureBooted(platform, deviceId);
    if (bootErr != null) {
      return (
        vmUri: null,
        deviceId: null,
        error: StructuredResponse.error(
          summary: 'could not boot device $deviceId',
          errorKind: GlintErrorKind.backendToolError,
          detail: bootErr,
        ),
      );
    }
    onProgress?.call(0, 'running flutter run');
    try {
      final r = await launcher.launchApp(
        projectDir: projectDir,
        deviceId: deviceId,
        timeout: Duration(milliseconds: session.config.launchTimeoutMs),
        onProgress: onProgress,
      );
      session.registerLaunchedApp(deviceId, r.process);
      return (vmUri: r.uri, deviceId: deviceId, error: null);
    } on LaunchError catch (e) {
      return (
        vmUri: null,
        deviceId: null,
        error: StructuredResponse.error(
          summary: 'failed to launch $projectDir',
          errorKind: GlintErrorKind.targetNotFound,
          detail: [e.message, if (e.logTail != null) '\n${e.logTail}'].join(),
          nextSteps: const [
            'check the build output in detail',
            'raise the wait for slow builds: config set launchTimeoutMs <ms>',
          ],
        ),
      );
    }
  }

  /// Launch an explicit project path (app not in history), on [deviceArg] or the single booted device.
  Future<({Uri? vmUri, String? deviceId, StructuredResponse? error})> _launchPath(
    GlintSession session,
    DiscoveryResult scan,
    String path,
    String? deviceArg,
    String? platformArg,
    void Function(int, String?)? onProgress,
  ) async {
    if (!File('$path/pubspec.yaml').existsSync()) {
      return (
        vmUri: null,
        deviceId: null,
        error: StructuredResponse.error(
          summary: 'no Flutter project at "$path"',
          errorKind: GlintErrorKind.invalidArgument,
          detail: 'expected a pubspec.yaml in that directory',
          nextSteps: const ['pass a Flutter project root path'],
        ),
      );
    }
    final platform = _platformFromArg(platformArg) ?? DevicePlatform.ios;
    final deviceId = deviceArg ?? _firstBootedId(scan, platform);
    if (deviceId == null) {
      return (
        vmUri: null,
        deviceId: null,
        error: StructuredResponse.error(
          summary: 'no device to launch on',
          errorKind: GlintErrorKind.targetNotFound,
          nextSteps: const ['boot a device, or pass device:"<udid/serial>"'],
        ),
      );
    }
    return _launchProject(session,
        projectDir: path,
        deviceId: deviceId,
        platform: platform,
        onProgress: onProgress);
  }

  /// Builds a 15s-cadence progress sink from the request's progress token, or null.
  void Function(int, String?)? _progressSink(
      GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    final totalSec = session.config.launchTimeoutMs / 1000;
    return (elapsedSec, phase) => notifier(ProgressNotification(
          progressToken: token,
          progress: elapsedSec,
          total: totalSec,
          message: phase == null
              ? 'launching… (${elapsedSec}s)'
              : '$phase (${elapsedSec}s)',
        ));
  }

  /// Most-recent launchable history record for [deviceId].
  AttachRecord? _historyForDevice(GlintSession session, String deviceId) {
    for (final r in session.attachHistory.load()) {
      if (r.deviceId == deviceId && r.launchable) return r;
    }
    return null;
  }

  /// Report "no app running" + previous launches and booted sims to pick from; errors only when there's nothing to offer.
  StructuredResponse _offerLaunch(
    GlintSession session,
    DiscoveryResult scan, {
    String? prefix,
  }) {
    final history = session.attachHistory.load();
    final launchable = history.where((r) => r.launchable).toList();

    if (launchable.isEmpty && scan.devices.isEmpty) {
      return StructuredResponse.error(
        summary: prefix ?? 'no app running, and nothing in history to start',
        errorKind: GlintErrorKind.targetNotFound,
        detail: history.isEmpty
            ? 'attach to a running app once and glint will remember it'
            : 'remembered apps have no tracked project dir',
        nextSteps: const [
          'start a Flutter app (flutter run), then call attach',
          'or attach in device mode (mode:"device") to drive a sim directly',
        ],
      );
    }

    return StructuredResponse(
      summary: prefix ?? 'no app running',
      nextSteps: [
        for (final r in launchable.take(5))
          'attach device:"${r.deviceId}"  → ${r.label} · '
              '${r.deviceName ?? r.platform} · ${_ago(r.lastSeen)}',
        for (final d in scan.devices)
          'attach mode:"device" device:"${d.id}"  (${d.name}) — drive the sim, no app',
      ],
      data: {
        'nothingRunning': true,
        'previousLaunches': [for (final r in launchable.take(10)) r.toJson()],
        'bootedDevices': [for (final d in scan.devices) d.toJson()],
      },
    );
  }

  String? _basename(String? path) {
    if (path == null || path.isEmpty) return null;
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.last;
  }

  DevicePlatform? _platformFromName(String name) => switch (name) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        _ => null,
      };

  String? _firstBootedId(DiscoveryResult scan, DevicePlatform platform) {
    final candidates = scan.devicesFor(platform);
    return candidates.isEmpty ? null : candidates.first.id;
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// A "needs selection" reply: not an error, but glint can't pick for the
  /// agent. Lists the candidates so the agent re-calls with an explicit choice.
  StructuredResponse _selection(
    String summary,
    DiscoveryResult d, {
    List<RunningApp>? running,
    GlintSession? session,
  }) {
    final pooled = session?.apps ?? const <AppSession>[];
    return StructuredResponse(
      summary: summary,
      nextSteps: [
        if (running != null)
          for (final r in running)
            r.label != null
                ? 'attach app:"${r.label}"  (${r.deviceName ?? r.deviceId ?? "device unknown"})'
                : r.deviceId != null
                    ? 'attach device:"${r.deviceId}"  (${r.deviceName ?? r.platform?.name ?? ""}, app name unknown)'
                    : 'attach vmUri:"${r.vmUri}"  (device not correlated)',
        if (running == null) for (final u in d.vmUris) 'vmUri: "$u"',
        for (final dev in d.devices)
          'device: "${dev.id}"  (${dev.name}, ${dev.platform.name})',
        for (final a in pooled)
          'already attached: app:"${a.label}" on ${a.deviceName ?? a.id}',
      ],
      data: {
        'needsSelection': true,
        'apps': running != null
            ? [for (final r in running) r.toJson()]
            : [for (final u in d.vmUris) u.toString()],
        'devices': [for (final dev in d.devices) dev.toJson()],
        if (session != null) 'attached': session.appsJson(),
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
