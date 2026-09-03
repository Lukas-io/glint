import 'dart:async';
import 'dart:io';

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../runtime/flutter_runtime.dart';
import 'capture_ring.dart';

/// Whether an app is read through the Flutter VM tree or the native OS AX tree.
enum SceneMode { flutter, native }

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
        attachedAt = DateTime.now();

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
  IconEnricher? iconEnricher;
  LinkEnricher? linkEnricher;
  NavigationEnricher? navEnricher;
  ReadinessGate? readinessGate;
  SettleDetector? settleDetector;
  NativeSceneReader? nativeReader;

  /// Identity filled in by `attach` once known; used for routing by name.
  String? package;
  String? displayName;
  String? bundleId;
  String? deviceName;

  /// Screen signature the last developer hint was issued for (one per screen).
  String? lastHintSignature;

  /// Background screenshots of this device, newest first.
  final CaptureRing captures = CaptureRing();

  /// Last lifecycle value the poll saw (`resumed`, `inactive`, `paused`, …).
  String? lastLifecycle;

  /// Wait after a lifecycle change before capturing, so the surface settles.
  int captureSettleMs = 700;

  int reconnectCount = 0;
  Timer? _lifecyclePollTimer;
  StreamSubscription<void>? _disconnectSub;
  bool _disposed = false;

  String get id => device.id;
  DevicePlatform get platform => device.platform;

  /// Best human label for this attachment.
  String get label =>
      displayName ?? package ?? bundleId ?? (deviceMode ? 'device' : 'app');

  /// A live VM (or a device-mode binding, which has nothing to lose).
  bool get isLive => deviceMode || (runtime?.isAttached ?? false);

  /// Connect a Flutter-mode session: attach the VM and build the pipeline.
  static Future<AppSession> connect({
    required Uri vmUri,
    required DeviceTarget device,
    required FlutterRuntime Function() runtimeFactory,
    int appLogCapacity = 500,
  }) async {
    final app = AppSession._(
      device: device,
      backend: device.createBackend(),
      deviceMode: false,
      appLogs: AppLogBuffer(capacity: appLogCapacity),
      vmUri: vmUri,
    );
    await app._bind(runtimeFactory);
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
    inspector = insp;
    reader = rd;
    resolver = res;
    interactor = Interactor(backend: backend, resolver: res);
    semanticizer = sem;
    overlayEnricher = OverlayEnricher(semanticizer: sem);
    inputEnricher = InputEnricher(runtime: rt, inspector: insp);
    toggleEnricher = ToggleEnricher(runtime: rt);
    iconEnricher = IconEnricher(runtime: rt);
    linkEnricher = LinkEnricher(runtime: rt);
    navEnricher = NavigationEnricher(runtime: rt);
    readinessGate = ReadinessGate(reader: rd, resolver: res);
    settleDetector = SettleDetector(runtime: rt, reader: rd);
    final dev = device;
    nativeReader = dev is IosSimulator
        ? NativeSceneReader(udid: dev.udid, bridgePath: dev.bridgePath)
        : null;

    try {
      await appLogs.subscribe(rt);
    } on Object {
      // best-effort — app logs stay empty, everything else works
    }

    await _disconnectSub?.cancel();
    _disconnectSub = rt.onDisconnect.listen((_) => _reconnect(runtimeFactory));

    _lifecyclePollTimer?.cancel();
    if (nativeReader != null) {
      _lifecyclePollTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _pollLifecycle(),
      );
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

  Future<void> dispose() async {
    _disposed = true;
    await _teardownRuntime();
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

  /// Re-read the lifecycle now instead of waiting for the next poll tick, so a
  /// read right after a native dialog closes does not report a stale mode.
  Future<void> refreshSceneMode() => _pollLifecycle();

  Future<void> _pollLifecycle() async {
    final rt = runtime;
    if (rt == null || nativeReader == null) return;
    try {
      final state = await rt.evaluateString(
        'WidgetsBinding.instance.lifecycleState?.name ?? "unknown"',
      );
      sceneMode = (state == null || state == 'resumed')
          ? SceneMode.flutter
          : SceneMode.native;
      _onLifecycle(state ?? 'resumed');
    } on Object {
      // Eval failure means the isolate is paused (native surface active).
      sceneMode = SceneMode.native;
      _onLifecycle('paused');
    }
  }
}
