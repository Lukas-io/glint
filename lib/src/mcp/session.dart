import 'dart:async';

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../runtime/flutter_runtime.dart';
import '../runtime/vm_service_runtime.dart';

/// Whether the session is reading the Flutter VM tree or the native OS AX tree.
enum SceneMode { flutter, native }

/// Per-connection state: runtime, device, readers, interactor. Tools
/// access these via the typed getters; accessing before [attach] throws
/// [SessionNotAttachedError]. [actionLog] is always available — survives
/// detach so cross-attach history stays queryable.
class GlintSession {
  GlintSession({
    GlintConfig? config,
    UsageRecorder? usage,
    AttachHistory? attachHistory,
    FlutterRuntime Function()? runtimeFactory,
  })  : config = config ?? GlintConfig(),
        actionLog = ActionLog(),
        appLogs = AppLogBuffer(),
        sessions = SessionManager(),
        usage = usage ?? UsageRecorder.fromEnv(),
        attachHistory =
            attachHistory ?? AttachHistory(dataDir: resolveDataDir()),
        _runtimeFactory = runtimeFactory ?? VmServiceRuntime.new {
    usageReporter = UsageReporter(this.usage);
  }

  final GlintConfig config;
  final ActionLog actionLog;
  final AppLogBuffer appLogs;
  final SessionManager sessions;

  /// Persistent app↔device↔project history so `attach` can relaunch from cold.
  final AttachHistory attachHistory;
  final UsageRecorder usage;
  late final UsageReporter usageReporter;
  final FlutterRuntime Function() _runtimeFactory;

  // ── reconnect ─────────────────────────────────────────────────────────────
  Uri? _lastVmUri;
  DeviceTarget? _lastDevice;
  int reconnectCount = 0;
  StreamSubscription<void>? _disconnectSub;

  // ── scene mode ────────────────────────────────────────────────────────────
  SceneMode sceneMode = SceneMode.flutter;
  Timer? _lifecyclePollTimer;

  // ── per-attach instances ──────────────────────────────────────────────────
  FlutterRuntime? _runtime;
  DeviceTarget? _device;
  InteractionBackend? _backend;
  InspectorClient? _inspector;
  SceneReader? _reader;
  CoordinateResolver? _resolver;
  Interactor? _interactor;
  Semanticizer? _semanticizer;
  OverlayEnricher? _overlayEnricher;
  InputEnricher? _inputEnricher;
  IconEnricher? _iconEnricher;
  NavigationEnricher? _navEnricher;
  ReadinessGate? _readinessGate;
  SettleDetector? _settleDetector;
  NativeSceneReader? _nativeReader;

  // Device mode: bound to an OS-level device with no Flutter VM. Only
  // [backend] + [device] are live; Flutter perception is unavailable.
  bool _deviceMode = false;

  bool get isAttached => _runtime != null || _deviceMode;
  bool get isDeviceMode => _deviceMode;

  FlutterRuntime get runtime => _requireAttached(_runtime, 'runtime');
  DeviceTarget get device => _requireAttached(_device, 'device');
  InteractionBackend get backend => _requireAttached(_backend, 'backend');
  InspectorClient get inspector => _requireAttached(_inspector, 'inspector');
  SceneReader get reader => _requireAttached(_reader, 'scene reader');
  CoordinateResolver get resolver => _requireAttached(_resolver, 'resolver');
  Interactor get interactor => _requireAttached(_interactor, 'interactor');
  Semanticizer get semanticizer => _requireAttached(_semanticizer, 'semanticizer');
  OverlayEnricher get overlayEnricher =>
      _requireAttached(_overlayEnricher, 'overlay enricher');
  InputEnricher get inputEnricher =>
      _requireAttached(_inputEnricher, 'input enricher');
  IconEnricher get iconEnricher =>
      _requireAttached(_iconEnricher, 'icon enricher');
  NavigationEnricher get navEnricher =>
      _requireAttached(_navEnricher, 'nav enricher');
  ReadinessGate get readinessGate =>
      _requireAttached(_readinessGate, 'readiness gate');
  SettleDetector get settleDetector =>
      _requireAttached(_settleDetector, 'settle detector');

  /// Null when the connected device is not an iOS simulator.
  NativeSceneReader? get nativeReader => _nativeReader;

  // ── lifecycle ─────────────────────────────────────────────────────────────

  /// Idempotent — re-attach replaces the previous connection.
  Future<void> attach({
    required Uri vmUri,
    required DeviceTarget device,
  }) async {
    if (_runtime != null) await detach();

    final runtime = _runtimeFactory();
    await runtime.attach(vmUri);

    final inspector = InspectorClient(runtime);
    final reader = SceneReader(inspector, runtime);
    final resolver = CoordinateResolver(runtime);
    final backend = device.createBackend();
    final interactor = Interactor(backend: backend, resolver: resolver);
    final semanticizer = Semanticizer();
    final overlayEnricher = OverlayEnricher(semanticizer: semanticizer);
    final inputEnricher = InputEnricher(runtime: runtime, inspector: inspector);
    final iconEnricher = IconEnricher(runtime: runtime);
    final navEnricher = NavigationEnricher(runtime: runtime);
    final readinessGate = ReadinessGate(reader: reader, resolver: resolver);
    final settleDetector = SettleDetector(runtime: runtime, reader: reader);

    _runtime = runtime;
    _device = device;
    _backend = backend;
    _inspector = inspector;
    _reader = reader;
    _resolver = resolver;
    _interactor = interactor;
    _semanticizer = semanticizer;
    _overlayEnricher = overlayEnricher;
    _inputEnricher = inputEnricher;
    _iconEnricher = iconEnricher;
    _navEnricher = navEnricher;
    _readinessGate = readinessGate;
    _settleDetector = settleDetector;

    _nativeReader = device is IosSimulator
        ? NativeSceneReader(udid: device.udid, bridgePath: device.bridgePath)
        : null;

    _lastVmUri = vmUri;
    _lastDevice = device;

    try {
      await appLogs.subscribe(runtime);
    } on Object {
      // best-effort — app logs stay empty, everything else works
    }

    // Watch for WebSocket disconnect and auto-reconnect (R2 + R3).
    _disconnectSub?.cancel();
    _disconnectSub = runtime.onDisconnect.listen((_) => _handleDisconnect());

    _lifecyclePollTimer?.cancel();
    _lifecyclePollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollLifecycle(),
    );
  }

  /// Attach in device mode — bind an OS-level device with no Flutter VM.
  /// Only [backend] + [device] are live; Flutter perception (scene reader,
  /// resolver, interactor) is not. Drive via screenshots + coordinate taps.
  Future<void> attachDevice({required DeviceTarget device}) async {
    if (_runtime != null || _deviceMode) await detach();
    _device = device;
    _backend = device.createBackend();
    _deviceMode = true;
    sceneMode = SceneMode.native;
  }

  /// Runs all semantic enrichers against [semantic]. Overlay must run first so
  /// [SemanticScene.overlayLayers] is populated before the renderer; the rest
  /// are order-independent.
  Future<void> runEnrichers(SemanticScene semantic) async {
    await overlayEnricher.enrich(semantic);
    await inputEnricher.enrich(semantic);
    await iconEnricher.enrich(semantic);
    await navEnricher.enrich(semantic);
  }

  Future<void> detach() async {
    _lifecyclePollTimer?.cancel();
    _lifecyclePollTimer = null;
    _disconnectSub?.cancel();
    _disconnectSub = null;
    _deviceMode = false;
    sceneMode = SceneMode.flutter;
    await appLogs.unsubscribe();
    final runtime = _runtime;
    _runtime = null;
    _device = null;
    _backend = null;
    _inspector = null;
    _reader = null;
    _resolver = null;
    _interactor = null;
    _semanticizer = null;
    _overlayEnricher = null;
    _inputEnricher = null;
    _iconEnricher = null;
    _navEnricher = null;
    _readinessGate = null;
    _settleDetector = null;
    _nativeReader = null;
    reconnectCount = 0;
    if (runtime != null) await runtime.disconnect();
  }

  // ── VM evals ──────────────────────────────────────────────────────────────

  /// Focused widget type + keyboard inset + orientation + brightness + locale.
  Future<
      ({
        String? focusedType,
        double keyboardBottomPx,
        String? orientation,
        String? brightness,
        String? locale,
      })> uiState() async {
    const empty = (
      focusedType: null,
      keyboardBottomPx: 0.0,
      orientation: null,
      brightness: null,
      locale: null,
    );
    final raw = await runtime.evaluateString(
      '((FocusManager.instance.primaryFocus?.context?.widget.runtimeType.toString() ?? "")'
          ' + "|" + '
          '(WidgetsBinding.instance.platformDispatcher.views.isEmpty ? "0"'
          ' : WidgetsBinding.instance.platformDispatcher.views.first.viewInsets.bottom.toString())'
          ' + "|" + '
          '(WidgetsBinding.instance.platformDispatcher.views.isEmpty ? "0"'
          ' : WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.aspectRatio.toString())'
          ' + "|" + '
          'WidgetsBinding.instance.platformDispatcher.platformBrightness.name'
          ' + "|" + '
          'WidgetsBinding.instance.platformDispatcher.locale.toString())',
    );
    if (raw == null) return empty;
    final parts = raw.split('|');
    final focusedType = parts[0].isEmpty ? null : parts[0];
    final kb = parts.length > 1 ? double.tryParse(parts[1]) ?? 0.0 : 0.0;
    final aspect = parts.length > 2 ? double.tryParse(parts[2]) ?? 0 : 0;
    final orientation =
        aspect == 0 ? null : (aspect > 1 ? 'landscape' : 'portrait');
    final brightness =
        parts.length > 3 && parts[3].isNotEmpty ? parts[3] : null;
    final locale = parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null;
    return (
      focusedType: focusedType,
      keyboardBottomPx: kb,
      orientation: orientation,
      brightness: brightness,
      locale: locale,
    );
  }

  /// One of: resumed, inactive, paused, detached, hidden. Null when unset.
  Future<String?> lifecycleState() async {
    final s = await runtime
        .evaluateString('WidgetsBinding.instance.lifecycleState?.name ?? ""');
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Logical viewport size + DPR, probed via geometry resolver on any
  /// addressable node. Used by direction-based scroll tools.
  Future<({double logicalW, double logicalH, double dpr})>
      probeViewport() async {
    final scene = await reader.readSummary();
    try {
      final probeId = scene.firstAddressableId();
      if (probeId == null) {
        throw StateError('no addressable node in scene to probe viewport from');
      }
      final c = await resolver.resolve(scene, probeId);
      return (
        logicalW: c.logicalViewSize.w,
        logicalH: c.logicalViewSize.h,
        dpr: c.devicePixelRatio,
      );
    } finally {
      await scene.dispose();
    }
  }

  // ── private ───────────────────────────────────────────────────────────────

  void _handleDisconnect() {
    final uri = _lastVmUri;
    final dev = _lastDevice;
    if (uri == null || dev == null) return;
    _reconnectAsync(uri, dev);
  }

  Future<void> _reconnectAsync(Uri uri, DeviceTarget dev) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        await attach(vmUri: uri, device: dev);
        reconnectCount++;
        return;
      } on Object {
        // keep retrying until exhausted
      }
    }
    // All retries failed — next tool call will surface connectionLost.
  }

  Future<void> _pollLifecycle() async {
    final rt = _runtime;
    if (rt == null) return;
    try {
      final state = await rt.evaluateString(
        'WidgetsBinding.instance.lifecycleState?.name ?? "unknown"',
      );
      sceneMode =
          (state == null || state == 'resumed') ? SceneMode.flutter : SceneMode.native;
    } on Object {
      // Eval failure means the isolate is paused (native surface active).
      sceneMode = SceneMode.native;
    }
  }

  T _requireAttached<T>(T? value, String name) {
    if (value == null) throw SessionNotAttachedError(missing: name);
    return value;
  }
}

class SessionNotAttachedError implements Exception {
  SessionNotAttachedError({required this.missing});
  final String missing;

  @override
  String toString() =>
      'glint session is not attached; call `attach` before using `$missing`';
}
