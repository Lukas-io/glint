import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart' show VmService;

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../interaction/emulator_control.dart' show EmulatorControl, EmulatorInstance;
import '../runtime/app_agent.dart';
import '../runtime/flutter_runtime.dart';
import 'capture_ring.dart';

/// Whether an app is read through the Flutter VM tree or the native OS AX tree.
enum SceneMode { flutter, native }

/// What an app answered when asked to show or hide touches; [errorKind] is set when it could not.
class TouchesOutcome {
  const TouchesOutcome(this.on,
      {this.system = false, this.systemDetail, this.errorKind, this.detail, this.nextSteps = const []});

  final bool on;

  /// Whether the device draws every real touch too (system dialogs, other apps, recordings), not just the Flutter app.
  final bool system;

  /// Why the device does not draw them, when touches are on.
  final String? systemDetail;
  final GlintErrorKind? errorKind;
  final String? detail;
  final List<String> nextSteps;

  bool get failed => errorKind != null;

  /// Where touches show, for a reply line.
  String get describe => !on
      ? 'hidden'
      : system
          ? 'shown everywhere (the device draws every touch, system dialogs and recordings included)'
          : 'shown in the Flutter app${systemDetail == null ? '' : '; not outside it: $systemDetail'}';

  Map<String, Object?> toJson() => {
        'on': on,
        if (system) 'system': true,
        if (errorKind != null) 'errorKind': errorKind!.name,
        if (detail != null) 'detail': detail,
      };
}

/// Everything one attachment owns: the VM runtime, the device backend, the
/// perception pipeline, app logs, reconnect and lifecycle watchers. A
/// [GlintSession] pools several of these and delegates to the active one.
class AppSession {
  AppSession._({
    required this.device,
    required this.backend,
    required this.deviceMode,
    required this.appLogs,
    this.vmUri,
  })  : sceneMode = deviceMode ? SceneMode.native : SceneMode.flutter,
        attachedAt = DateTime.now() {
    if (backend case final FlutterInputBackend routed) routed.touchLog = touchLog;
  }

  /// Every touch glint sent to this app's device, for drawing onto recordings.
  final touchLog = TouchLog();

  final DeviceTarget device;
  final Uri? vmUri;
  final bool deviceMode;
  final AppLogBuffer appLogs;
  final DateTime attachedAt;
  InteractionBackend backend;
  SceneMode sceneMode;

  FlutterRuntime? runtime;
  InspectorClient? inspector;
  SceneReader? reader;
  CoordinateResolver? resolver;
  Interactor? interactor;
  Semanticizer? semanticizer;
  OverlayEnricher? overlayEnricher;
  InputEnricher? inputEnricher;
  ToggleEnricher? toggleEnricher;
  SemanticsFlagEnricher? flagEnricher;
  TabLabelEnricher? tabEnricher;
  ButtonFactsEnricher? buttonEnricher;
  OpaqueWidgetEnricher? opaqueEnricher;
  InertEnricher? inertEnricher;
  ImageEnricher? imageEnricher;
  MapEnricher? mapEnricher;
  IconEnricher? iconEnricher;
  LinkEnricher? linkEnricher;
  NavigationEnricher? navEnricher;
  PagedViewportEnricher? pagedEnricher;
  ReadinessGate? readinessGate;
  SettleDetector? settleDetector;
  NativeReader? nativeReader;

  /// Native crashes of this app since attach: the simulator's crash reports on iOS, the crash log buffer on Android.
  Future<List<NativeCrash>> nativeCrashes() async {
    final since = attachedAt.subtract(const Duration(seconds: 5));
    final dev = device;
    switch (dev) {
      case IosSimulator():
        final id = bundleId;
        return id == null ? const [] : iosCrashes(bundleId: id, since: since);
      case IosDevice():
        final id = bundleId;
        return id == null ? const [] : phoneCrashes(udid: dev.udid, bundleId: id, since: since);
      case AndroidDevice():
        final reader = nativeReader;
        final pkg = (reader is AndroidNativeReader ? reader.appPackage : null) ?? package;
        return pkg == null
            ? const []
            : androidCrashes(serial: dev.serial, adbPath: dev.adbPath, package: pkg, since: since);
    }
  }

  /// The foreign window in front of the app at the last check (Android), e.g. a system photo picker.
  String? nativeSurfaceName;

  /// Identity filled in by `attach` once known; used for routing by name.
  String? package;
  String? displayName;
  String? bundleId;
  String? deviceName;

  /// Flutter project root behind the app, when attach could resolve it.
  String? projectDir;

  /// Screen signature the last developer hint was issued for (one per screen).
  String? lastHintSignature;

  /// Background screenshots of this device, newest first.
  final CaptureRing captures = CaptureRing();

  /// Log breakpoints armed on this app; they pause its UI isolate when a log line matches.
  late final LogBreakpoints breakpoints = LogBreakpoints(
    pauseApp: () => _isolateCall((service, id) => service.pause(id)),
    resumeApp: () => _isolateCall((service, id) => service.resume(id)),
    capture: () async => (await captureNow('breakpoint'))?.path,
  )..listen(appLogs.onEntry);

  /// Runs a VM call on the UI isolate; returns the failure as text, or null on success.
  Future<String?> _isolateCall(Future<Object?> Function(VmService service, String isolateId) call) async {
    final rt = runtime;
    if (rt == null || !rt.isAttached) return 'not connected to the app\'s VM service';
    try {
      await call(rt.rawService, rt.flutterIsolateId).timeout(const Duration(seconds: 5));
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  /// A recording in flight (set by the record tool); stopped on dispose so a crash mid-record does not orphan the simctl/adb process.
  ScreenRecording? activeRecording;

  /// Last lifecycle value the poll saw (`resumed`, `inactive`, `paused`, …).
  String? lastLifecycle;

  /// Wait after a lifecycle change before capturing, so the surface settles.
  int captureSettleMs = 700;

  /// Whether the app draws each touch; carried into every agent this app gets (reconnect, hot restart).
  bool showTouches = false;

  int reconnectCount = 0;
  Timer? _lifecyclePollTimer;
  StreamSubscription<void>? _disconnectSub;
  StreamSubscription<String>? _lifecycleSub;
  bool _disposed = false;

  String get id => device.id;
  DevicePlatform get platform => device.platform;

  /// Best human label for this attachment.
  String get label => displayName ?? package ?? bundleId ?? (deviceMode ? 'device' : 'app');

  /// A live VM (or a device-mode binding, which has nothing to lose).
  bool get isLive => deviceMode || (runtime?.isAttached ?? false);

  /// Connect a Flutter-mode session: attach the VM and build the pipeline.
  static Future<AppSession> connect({
    required Uri vmUri,
    required DeviceTarget device,
    required FlutterRuntime Function() runtimeFactory,
    int appLogCapacity = 500,
    bool showTouches = false,
  }) async {
    final app = AppSession._(
      device: device,
      backend: device.createBackend(),
      deviceMode: false,
      appLogs: AppLogBuffer(capacity: appLogCapacity),
      vmUri: vmUri,
    )..showTouches = showTouches;
    await app._bind(runtimeFactory);
    await app._restoreStaleSystemTouches();
    return app;
  }

  /// Bind an OS-level device with no Flutter VM (screenshots + coordinates).
  static AppSession bindDevice({required DeviceTarget device}) => AppSession._(
        device: device,
        backend: device.createBackend(),
        deviceMode: true,
        appLogs: AppLogBuffer(),
      );

  /// True when [query] names this session: device id, app identity, or a
  /// case-insensitive prefix of the app or device name.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    if (id.toLowerCase() == q) return true;
    for (final s in [package, displayName, bundleId, deviceName]) {
      if (s == null) continue;
      final v = s.toLowerCase();
      if (v == q || v.startsWith(q)) return true;
    }
    return false;
  }

  Map<String, Object?> toJson({bool active = false}) => {
        'device': id,
        'platform': platform.name,
        if (deviceName != null) 'deviceName': deviceName,
        if (!deviceMode) 'app': label,
        if (package != null) 'package': package,
        if (bundleId != null) 'bundleId': bundleId,
        if (projectDir != null) 'project': projectDir,
        'mode': deviceMode ? 'device' : 'flutter',
        if (vmUri != null) 'vmUri': vmUri.toString(),
        'live': isLive,
        if (active) 'active': true,
      };

  Future<void> _bind(FlutterRuntime Function() runtimeFactory) async {
    final rt = runtimeFactory();
    await rt.attach(vmUri!);

    final insp = InspectorClient(rt);
    final rd = SceneReader(insp, rt);
    final res = CoordinateResolver(rt);
    final sem = Semanticizer();

    runtime = rt;
    AppAgent.of(rt)?.showTouches = showTouches;
    if (backend case final FlutterInputBackend routed) routed.runtime = rt;
    inspector = insp;
    reader = rd;
    resolver = res;
    interactor = Interactor(backend: backend, resolver: res);
    semanticizer = sem;
    overlayEnricher = OverlayEnricher(semanticizer: sem);
    inputEnricher = InputEnricher(runtime: rt, inspector: insp);
    toggleEnricher = ToggleEnricher(runtime: rt);
    flagEnricher = SemanticsFlagEnricher(runtime: rt);
    tabEnricher = TabLabelEnricher(runtime: rt);
    buttonEnricher = ButtonFactsEnricher(runtime: rt);
    opaqueEnricher = OpaqueWidgetEnricher(runtime: rt);
    inertEnricher = InertEnricher(runtime: rt);
    imageEnricher = ImageEnricher(runtime: rt);
    mapEnricher = MapEnricher(runtime: rt);
    iconEnricher = IconEnricher(runtime: rt);
    linkEnricher = LinkEnricher(runtime: rt);
    navEnricher = NavigationEnricher(runtime: rt);
    pagedEnricher = PagedViewportEnricher(resolver: res);
    readinessGate = ReadinessGate(reader: rd, resolver: res);
    settleDetector = SettleDetector(runtime: rt, reader: rd);
    final dev = device;
    nativeReader = switch (dev) {
      IosSimulator(:final runner?) => RunnerNativeReader(
          tree: (bundleId) => runner.call(
              'GET', '/tree${bundleId == null ? '' : '?app=${Uri.encodeQueryComponent(bundleId)}'}',
              timeout: const Duration(seconds: 5)),
          bundleId: () => bundleId,
          fallback: NativeSceneReader(udid: dev.udid, bridgePath: dev.bridgePath),
        ),
      IosSimulator() => NativeSceneReader(udid: dev.udid, bridgePath: dev.bridgePath),
      IosDevice() => OcrNativeReader(
          capture: () async {
            final shot = await backend.screenshot('${Directory.systemTemp.path}/glint-native-${dev.udid}.png');
            return shot.error == null ? shot.path : null;
          },
          recognize: readText,
          devicePixelRatio: () => dev.devicePixelRatio,
        ),
      AndroidDevice() => AndroidNativeReader(
          serial: dev.serial,
          adbPath: dev.adbPath,
          devicePixelRatio: () => dev.devicePixelRatio,
          serverCall: _serverCall(dev.server),
        ),
    };
    if (backend case final FlutterInputBackend routed) {
      final reader = nativeReader;
      routed.coveredBySystem = reader is AndroidNativeReader ? () => _foreignWindowUp(reader) : null;
    }

    try {
      await appLogs.subscribe(rt);
    } on Object {
      // best-effort — app logs stay empty, everything else works
    }

    await _disconnectSub?.cancel();
    _disconnectSub = rt.onDisconnect.listen((_) => _reconnect(runtimeFactory));

    _lifecyclePollTimer?.cancel();
    final pushed = await _subscribeLifecycle(rt);
    final polled = nativeReader is RunnerNativeReader ||
        (!pushed && (nativeReader is NativeSceneReader || nativeReader is OcrNativeReader));
    if (polled) {
      _lifecyclePollTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pollLifecycle(background: true),
      );
    }
  }

  /// Installs glint's in-app agent and follows the lifecycle changes it posts; false when the app cannot host it, so the caller polls instead.
  Future<bool> _subscribeLifecycle(FlutterRuntime rt) async {
    final agent = AppAgent.of(rt);
    if (agent == null) return false;
    await _lifecycleSub?.cancel();
    _lifecycleSub = agent.lifecycle.listen((state) {
      if (nativeReader != null && nativeSurfaceName == null) {
        sceneMode = state == 'resumed' ? SceneMode.flutter : SceneMode.native;
      }
      _onLifecycle(state);
    });
    try {
      final now = await agent.call(const {'op': 'lifecycle'}).timeout(lifecycleProbeTimeout);
      final state = '${now['state']}';
      if (nativeReader != null && nativeSurfaceName == null) {
        sceneMode = state == 'resumed' ? SceneMode.flutter : SceneMode.native;
      }
      _onLifecycle(state);
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _reconnect(FlutterRuntime Function() runtimeFactory) async {
    for (var attempt = 1; attempt <= 3 && !_disposed; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        await _teardownRuntime();
        await _bind(runtimeFactory);
        reconnectCount++;
        return;
      } on Object {
        // keep retrying until exhausted
      }
    }
    // All retries failed — the next tool call surfaces connectionLost.
  }

  Future<void> _teardownRuntime() async {
    _lifecyclePollTimer?.cancel();
    _lifecyclePollTimer = null;
    await _lifecycleSub?.cancel();
    _lifecycleSub = null;
    await _disconnectSub?.cancel();
    _disconnectSub = null;
    await appLogs.unsubscribe();
    final rt = runtime;
    runtime = null;
    if (rt != null) {
      try {
        await rt.disconnect();
      } on Object {
        // already gone
      }
    }
  }

  /// Shows or hides a dot for each touch inside the app; never throws.
  Future<TouchesOutcome> setShowTouches(bool on) async {
    showTouches = on;
    final system = await _setSystemTouches(on);
    final rt = runtime;
    final agent = rt == null || deviceMode ? null : AppAgent.of(rt);
    if (agent == null && system.on) return const TouchesOutcome(true, system: true);
    if (agent == null) {
      return TouchesOutcome(false,
          errorKind: GlintErrorKind.flutterModeRequired,
          detail: 'touches are drawn inside the Flutter app, and $label is in device mode with no Flutter VM',
          nextSteps: const ['attach to the running Flutter app (without mode:"device") to show touches']);
    }
    try {
      final reply = await agent.setTouches(on, ownOnly: system.on);
      if (reply['on'] == on) return TouchesOutcome(on, system: system.on, systemDetail: system.why);
      return TouchesOutcome(false,
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: reply['reason'] == 'notDebug'
              ? 'the app runs without asserts (not a debug build), and Flutter only draws debug overlays in debug builds'
              : 'the in-app agent answered ${reply['reason'] ?? reply}',
          nextSteps: const ['run the app in debug mode (flutter run), then attach again']);
    } on RuntimeConnectionLostError catch (e) {
      return TouchesOutcome(false,
          errorKind: GlintErrorKind.connectionLost,
          detail: '$e',
          nextSteps: const ['relaunch the app, then `attach` again']);
    } on RuntimeUnresponsiveError catch (e) {
      return TouchesOutcome(false,
          errorKind: GlintErrorKind.appUnresponsive,
          detail: '$e',
          nextSteps: const ['if a debugger paused the app, resume it; then set showTouches again']);
    } on Object catch (e) {
      return TouchesOutcome(false,
          errorKind: GlintErrorKind.backendToolError,
          detail: '$e',
          nextSteps: const ['set showTouches again; if it keeps failing, `report_issue` with the user\'s OK']);
    }
  }

  EmulatorTouches? _emulatorTouches;

  /// Has the device draw every real touch where glint can (an Android emulator's `show_touches`, with input through its own touchscreen); `why` says why not when [on].
  Future<({bool on, String? why})> _setSystemTouches(bool on) async {
    final dev = device;
    final b = backend;
    final adb = b is FlutterInputBackend ? b.native : b;
    if (dev is! AndroidDevice || adb is! AdbBackend) {
      return (on: false, why: on ? 'this device draws no touches of its own for glint' : null);
    }
    final setting = ShowTouchesSetting(adbPath: dev.adbPath, serial: dev.serial);
    if (!on) {
      adb.systemTouches = null;
      final t = _emulatorTouches;
      _emulatorTouches = null;
      try {
        await t?.close();
        await setting.restore();
      } on Object catch (e) {
        return (on: false, why: 'could not put Android\'s show_touches setting back: $e');
      }
      return (on: false, why: null);
    }
    if (!dev.serial.startsWith('emulator-')) {
      return (on: false, why: 'Android draws only touches from a phone\'s own screen, and glint injects them');
    }
    final emulator = await EmulatorInstance.locate(dev.serial, adbPath: dev.adbPath);
    final grpc = emulator?.grpc;
    if (grpc == null) {
      return (on: false, why: emulator?.noControlReason ?? '${dev.serial} serves no gRPC control for its touchscreen');
    }
    try {
      await setting.enable();
    } on Object catch (e) {
      return (on: false, why: 'could not switch Android\'s show_touches setting on: $e');
    }
    final t = EmulatorTouches(EmulatorControl(grpc));
    _emulatorTouches = t;
    adb.systemTouches = t;
    return (on: true, why: null);
  }

  /// Puts back an Android `show_touches` setting a glint that exited without detaching left on.
  Future<void> _restoreStaleSystemTouches() async {
    final dev = device;
    if (showTouches || dev is! AndroidDevice) return;
    final setting = ShowTouchesSetting(adbPath: dev.adbPath, serial: dev.serial);
    if (!setting.pending) return;
    try {
      await setting.restore();
    } on Object {
      // best-effort; the next attach tries again
    }
  }

  Future<void> dispose() async {
    await breakpoints.dispose();
    _disposed = true;
    if (showTouches) await _setSystemTouches(false);
    final rt = runtime;
    if (showTouches && rt != null && rt.isAttached) {
      try {
        await AppAgent.of(rt)?.setTouches(false).timeout(const Duration(seconds: 2));
      } on Object {
        // best-effort; the app may already be gone
      }
    }
    final rec = activeRecording;
    activeRecording = null;
    if (rec != null) {
      try {
        await rec.stop();
      } on Object {
        // best-effort; the recorder process is killed with our children anyway
      }
    }
    await _teardownRuntime();
    await backend.close();
    captures.clear();
  }

  /// Screenshot this device into the ring. Null on failure; never throws.
  Future<Capture?> captureNow(String trigger) async {
    if (_disposed) return null;
    final dir = Directory('${Directory.systemTemp.path}/glint-captures/$id');
    final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.png';
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final shot = await backend.screenshot(path);
      if (shot.error != null || shot.path == null) return null;
      final c = Capture(
        path: shot.path!,
        takenAt: DateTime.now(),
        trigger: trigger,
        lifecycle: lastLifecycle,
        width: shot.width,
        height: shot.height,
      );
      captures.add(c);
      return c;
    } on Object {
      return null;
    }
  }

  /// A lifecycle transition away from resumed (or between non-resumed states)
  /// schedules one capture after [captureSettleMs]. Fire-and-forget.
  void _onLifecycle(String? state) {
    final previous = lastLifecycle;
    lastLifecycle = state;
    final leftResumed = state != null && state != 'resumed' && state != previous;
    if (!leftResumed) return;
    Future<void>.delayed(Duration(milliseconds: captureSettleMs), () async {
      if (_disposed || lastLifecycle != state) return;
      await captureNow('lifecycle');
    });
  }

  /// Whether a window other than the app's has focus; false when it cannot tell, so the check never blocks input.
  Future<bool> _foreignWindowUp(AndroidNativeReader reader) async {
    if (reader.appPackage == null && bundleId != null) reader.appPackage = bundleId;
    try {
      return await reader.foreignSurface() != null;
    } on Object {
      return false;
    }
  }

  /// Re-read the lifecycle now instead of waiting for the next poll tick, so a
  /// read right after a native dialog closes does not report a stale mode.
  Future<void> refreshSceneMode() => _pollLifecycle();

  /// A suspended app (device locked, backgrounded) never answers; a live one answers well inside this.
  static const lifecycleProbeTimeout = Duration(seconds: 2);

  int _backgroundTicks = 0;

  /// A [background] tick reads the runner's tree (about 90 ms) only every fourth time; actions and `get_scene` always do.
  Future<void> _pollLifecycle({bool background = false}) async {
    final rt = runtime;
    final native = nativeReader;
    if (rt == null || native == null) return;
    if (native is AndroidNativeReader && native.appPackage == null && bundleId != null) {
      native.appPackage = bundleId;
    }
    if (native is AndroidNativeReader && native.appPackage == null) {
      try {
        final s = await rt
            .evaluateString('WidgetsBinding.instance.lifecycleState?.name ?? ""')
            .timeout(lifecycleProbeTimeout);
        if (s == 'resumed') await native.learnAppPackage();
      } on Object {
        // not learnable yet; the next poll tries again
      }
    }
    final skipForeign = background && native is RunnerNativeReader && _backgroundTicks++ % 4 != 0;
    final foreign = skipForeign ? nativeSurfaceName : await native.foreignSurface();
    nativeSurfaceName = foreign;
    if (foreign != null) {
      sceneMode = SceneMode.native;
      return;
    }
    try {
      final state = await rt
          .evaluateString(
            'WidgetsBinding.instance.lifecycleState?.name ?? "unknown"',
          )
          .timeout(lifecycleProbeTimeout);
      sceneMode = (state == null || state == 'resumed') ? SceneMode.flutter : SceneMode.native;
      _onLifecycle(state ?? 'resumed');
    } on TimeoutException {
      // Slow is not suspended (the first eval also resolves the eval library); only a locked device settles it.
      bool? locked;
      try {
        locked = await backend.lockState();
      } on Object {
        locked = null;
      }
      if (locked == true) {
        sceneMode = SceneMode.native;
        _onLifecycle('paused');
      }
    } on Object {
      // Eval failure means the isolate is paused (native surface active).
      sceneMode = SceneMode.native;
      _onLifecycle('paused');
    }
  }
}

/// A call into [server] for the native reader, null when there is no server or it failed.
Future<Map<String, Object?>?> Function(Map<String, Object?>)? _serverCall(AndroidServer? server) {
  if (server == null) return null;
  return (request) async {
    if (!server.running) return null;
    try {
      return await server.call(request);
    } on AndroidServerError {
      return null;
    }
  };
}
