import 'dart:async';
import 'dart:io' show Process;

import 'package:dart_mcp/server.dart' show ProgressNotification;

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../runtime/flutter_runtime.dart';
import '../runtime/vm_service_runtime.dart';
import 'app_session.dart';

export 'app_session.dart' show AppSession, SceneMode;

/// How far to enrich a scene: [structural] = overlays + route (cheap);
/// [interactive] = also input values + toggle states (change-detection);
/// [full] = also icon names + inline link detection (for rendering).
enum SceneDetail { structural, interactive, full }

/// Per-connection state: a pool of attached apps (one per device) plus the
/// active one every tool reads through. Getters delegate to the active
/// [AppSession]; accessing them with nothing attached throws
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
        sessions = SessionManager(),
        usage = usage ?? UsageRecorder.fromEnv(),
        attachHistory =
            attachHistory ?? AttachHistory(dataDir: resolveDataDir()),
        _runtimeFactory = runtimeFactory ?? VmServiceRuntime.new {
    usageReporter = UsageReporter(this.usage);
  }

  final GlintConfig config;
  final ActionLog actionLog;
  final SessionManager sessions;

  /// Persistent app↔device↔project history so `attach` can relaunch from cold.
  final AttachHistory attachHistory;
  final UsageRecorder usage;
  late final UsageReporter usageReporter;
  final FlutterRuntime Function() _runtimeFactory;

  // ── pool ──────────────────────────────────────────────────────────────────
  final Map<String, AppSession> _pool = {};
  AppSession? _active;

  /// Logs of the last detached app, so `app_logs` keeps answering after detach.
  AppLogBuffer _orphanLogs = AppLogBuffer();

  /// Forwards [ProgressNotification]s to the client; wired by the server.
  void Function(ProgressNotification)? progressNotifier;

  /// `flutter run` processes glint started, keyed by device id, for `kill_app`.
  final Map<String, Process> _launchedApps = {};

  void registerLaunchedApp(String deviceId, Process process) =>
      _launchedApps[deviceId] = process;

  Process? launchedAppFor(String deviceId) => _launchedApps[deviceId];

  void clearLaunchedApp(String deviceId) => _launchedApps.remove(deviceId);

  /// Kills every `flutter run` process glint started. Called from the server
  /// shutdown path so a dying glint never orphans its children.
  void killLaunchedApps() {
    for (final process in _launchedApps.values) {
      try {
        process.kill();
      } catch (_) {/* already dead */}
    }
    _launchedApps.clear();
  }

  // ── active app ────────────────────────────────────────────────────────────
  AppSession? get active => _active;

  /// Every attached app, most recently attached first.
  List<AppSession> get apps => _pool.values.toList()
    ..sort((a, b) => b.attachedAt.compareTo(a.attachedAt));

  List<Map<String, Object?>> appsJson() =>
      [for (final a in apps) a.toJson(active: identical(a, _active))];

  AppSession? appFor(String deviceId) => _pool[deviceId];
  bool hasApp(String deviceId) => _pool.containsKey(deviceId);

  /// The pooled session already bound to [vmUri], if any.
  AppSession? appForVm(Uri vmUri) {
    for (final a in _pool.values) {
      if (a.vmUri == vmUri) return a;
    }
    return null;
  }

  /// Sessions matching [target] (device id, app name/package/bundle id, or a
  /// device-name prefix). An exact device-id or full-label hit wins alone.
  List<AppSession> matchApps(String target) {
    final q = target.trim().toLowerCase();
    final exact = _pool.values.where((a) =>
        a.id.toLowerCase() == q ||
        a.package?.toLowerCase() == q ||
        a.displayName?.toLowerCase() == q ||
        a.bundleId?.toLowerCase() == q);
    if (exact.isNotEmpty) return exact.toList();
    return _pool.values.where((a) => a.matches(target)).toList();
  }

  /// One session for [target], or null when none / several match.
  AppSession? findApp(String target) {
    final m = matchApps(target);
    return m.length == 1 ? m.single : null;
  }

  void activate(AppSession app) => _active = app;

  /// Runs [body] with [target] active, restoring the previous active app
  /// afterwards — the per-call `app:` routing every tool supports.
  Future<T> withApp<T>(AppSession target, Future<T> Function() body) async {
    final previous = _active;
    _active = target;
    try {
      return await body();
    } finally {
      if (_pool.containsValue(previous) || previous == null) {
        _active = previous;
      }
    }
  }

  bool get isAttached => _active != null;
  bool get isDeviceMode => _active?.deviceMode ?? false;

  SceneMode get sceneMode => _active?.sceneMode ?? SceneMode.flutter;
  set sceneMode(SceneMode m) => _active?.sceneMode = m;

  /// Bundle id / package of the active app, when known — used by `kill_app`.
  String? get attachedBundleId => _active?.bundleId;
  set attachedBundleId(String? v) => _active?.bundleId = v;

  int get reconnectCount => _active?.reconnectCount ?? 0;

  AppLogBuffer get appLogs => _active?.appLogs ?? _orphanLogs;

  FlutterRuntime get runtime => _requireAttached(_active?.runtime, 'runtime');
  DeviceTarget get device => _requireAttached(_active?.device, 'device');
  InteractionBackend get backend =>
      _requireAttached(_active?.backend, 'backend');
  InspectorClient get inspector =>
      _requireAttached(_active?.inspector, 'inspector');
  SceneReader get reader => _requireAttached(_active?.reader, 'scene reader');
  CoordinateResolver get resolver =>
      _requireAttached(_active?.resolver, 'resolver');
  Interactor get interactor =>
      _requireAttached(_active?.interactor, 'interactor');
  Semanticizer get semanticizer =>
      _requireAttached(_active?.semanticizer, 'semanticizer');
  OverlayEnricher get overlayEnricher =>
      _requireAttached(_active?.overlayEnricher, 'overlay enricher');
  InputEnricher get inputEnricher =>
      _requireAttached(_active?.inputEnricher, 'input enricher');
  ToggleEnricher get toggleEnricher =>
      _requireAttached(_active?.toggleEnricher, 'toggle enricher');
  IconEnricher get iconEnricher =>
      _requireAttached(_active?.iconEnricher, 'icon enricher');
  LinkEnricher get linkEnricher =>
      _requireAttached(_active?.linkEnricher, 'link enricher');
  NavigationEnricher get navEnricher =>
      _requireAttached(_active?.navEnricher, 'nav enricher');
  ReadinessGate get readinessGate =>
      _requireAttached(_active?.readinessGate, 'readiness gate');
  SettleDetector get settleDetector =>
      _requireAttached(_active?.settleDetector, 'settle detector');

  /// Null when the active device is not an iOS simulator.
  NativeSceneReader? get nativeReader => _active?.nativeReader;

  // ── lifecycle ─────────────────────────────────────────────────────────────

  /// Attach (or switch to) the app at [vmUri] on [device]. A pooled session
  /// bound to the same VM is activated as-is; a different app on the same
  /// device replaces the old entry. Other pooled apps stay connected.
  Future<AppSession> attach({
    required Uri vmUri,
    required DeviceTarget device,
  }) async {
    final existing = _pool[device.id];
    if (existing != null &&
        !existing.deviceMode &&
        existing.vmUri == vmUri &&
        existing.isLive) {
      _active = existing;
      return existing;
    }
    if (existing != null) await _drop(existing);
    final app = await AppSession.connect(
      vmUri: vmUri,
      device: device,
      runtimeFactory: _runtimeFactory,
      appLogCapacity: config.appLogCapacity,
    );
    _pool[device.id] = app;
    _active = app;
    return app;
  }

  /// Attach in device mode — bind an OS-level device with no Flutter VM.
  /// Only [backend] + [device] are live; Flutter perception (scene reader,
  /// resolver, interactor) is not. Drive via screenshots + coordinate taps.
  Future<AppSession> attachDevice({required DeviceTarget device}) async {
    final existing = _pool[device.id];
    if (existing != null) await _drop(existing);
    final app = AppSession.bindDevice(device: device);
    _pool[device.id] = app;
    _active = app;
    return app;
  }

  /// Detach one app (the active one by default) and drop it from the pool.
  /// When exactly one other app remains it becomes active.
  Future<void> detach({String? deviceId}) async {
    final target = deviceId != null ? _pool[deviceId] : _active;
    if (target == null) return;
    await _drop(target);
    if (_active == null && _pool.length == 1) _active = _pool.values.single;
  }

  Future<void> detachAll() async {
    for (final app in _pool.values.toList()) {
      await _drop(app);
    }
  }

  Future<void> _drop(AppSession app) async {
    _pool.remove(app.id);
    if (identical(_active, app)) {
      _active = null;
      _orphanLogs = app.appLogs;
    }
    await app.dispose();
  }

  /// The single perceive entry: read the scene, semanticize, enrich to
  /// [detail], hand it to [use], then dispose. Callers never re-assemble the
  /// pipeline themselves.
  Future<T> withScene<T>(
    Future<T> Function(SemanticScene scene) use, {
    SceneDetail detail = SceneDetail.full,
  }) async {
    final scene = await reader.readSummary();
    try {
      return await use(await semanticize(scene, detail: detail));
    } finally {
      await scene.dispose();
    }
  }

  /// Semanticize + enrich an already-read [scene] to [detail]. The caller
  /// still owns the scene's dispose.
  Future<SemanticScene> semanticize(
    Scene scene, {
    SceneDetail detail = SceneDetail.full,
  }) async {
    final semantic = semanticizer.semanticize(scene);
    // Overlay first so overlayLayers is populated before anything renders;
    // the rest are order-independent.
    await overlayEnricher.enrich(semantic);
    await navEnricher.enrich(semantic);
    if (detail != SceneDetail.structural) {
      await inputEnricher.enrich(semantic);
      await toggleEnricher.enrich(semantic);
    }
    if (detail == SceneDetail.full) {
      await iconEnricher.enrich(semantic);
      await linkEnricher.enrich(semantic);
    }
    return semantic;
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
      return await viewportIn(scene);
    } finally {
      await scene.dispose();
    }
  }

  /// [probeViewport] against a scene the caller already holds. The implicit
  /// view answers without a node; a selected node is the fallback.
  Future<({double logicalW, double logicalH, double dpr})> viewportIn(
      Scene scene) async {
    try {
      final v = await resolver.resolveViewportNodeFree();
      return (logicalW: v.w, logicalH: v.h, dpr: v.dpr);
    } on GeometryResolveError {
      // fall back to a node-anchored probe below
    }
    final probeId = scene.firstAddressableId();
    if (probeId == null) {
      throw GeometryResolveError(
          'no addressable node in scene to probe viewport from');
    }
    final c = await resolver.resolve(scene, probeId);
    return (
      logicalW: c.logicalViewSize.w,
      logicalH: c.logicalViewSize.h,
      dpr: c.devicePixelRatio,
    );
  }

  /// Reference point inside the primary scrollable, for scroll-displacement
  /// detection: (glintId, logicalCenter). A fully-realized scrollable
  /// (SingleChildScrollView) has an identical tree at every offset, so we
  /// measure a descendant's physical shift instead. Null when there's no
  /// scrollable or no resolvable descendant.
  Future<({String glintId, double x, double y})?> probeScrollAnchor() async {
    final scene = await reader.readSummary();
    try {
      return await scrollAnchorIn(scene, semanticizer.semanticize(scene));
    } finally {
      await scene.dispose();
    }
  }

  /// [probeScrollAnchor] against a scene + semantic view the caller holds.
  Future<({String glintId, double x, double y})?> scrollAnchorIn(
      Scene scene, SemanticScene semantic) async {
    final list = semantic.root.walk().whereType<SemanticList>().firstOrNull;
    if (list == null) return null;
    for (final n in list.walk()) {
      final id = n.glintId;
      if (id == null) continue;
      try {
        final c = await resolver.resolve(scene, id);
        if (c.hasNonZeroBounds) {
          return (glintId: id, x: c.logicalCenter.x, y: c.logicalCenter.y);
        }
      } on Object {
        // unresolvable node — try the next descendant
      }
    }
    return null;
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
