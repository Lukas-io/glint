import 'dart:async';
import 'dart:io' show Process;

import 'package:dart_mcp/server.dart' show ProgressNotification;

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../interaction/image_size.dart';
import '../runtime/flutter_runtime.dart';
import '../runtime/vm_service_runtime.dart';
import 'app_session.dart';
import 'post_action.dart' show ScrollAnchor;
import 'watch_registry.dart';

export 'app_session.dart' show AppSession, SceneMode, TouchesOutcome;
export 'capture_ring.dart';

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
        attachHistory = attachHistory ?? AttachHistory(dataDir: resolveDataDir()),
        _runtimeFactory = runtimeFactory ?? VmServiceRuntime.new {
    usageReporter = UsageReporter(this.usage);
  }

  final GlintConfig config;

  /// Whether attach already told the agent a newer glint is out, so it says so once per session.
  bool updateNoticeShown = false;
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
  final Object _bindingKey = Object();

  /// Logs of the last detached app, so `app_logs` keeps answering after detach.
  AppLogBuffer _orphanLogs = AppLogBuffer();

  static const _retainedLogLimit = 4;

  /// Log buffers of recently detached Flutter apps, oldest first, so re-attaching the same app process continues them.
  final List<_RetainedLogs> _retainedLogs = [];

  /// Per-device warning that a re-attach started a fresh log buffer, read once by `attach`.
  final Map<String, String> _logNotes = {};

  /// The warning for [deviceId] when its last re-attach could not continue the earlier app logs.
  String? takeLogNote(String deviceId) => _logNotes.remove(deviceId);

  /// Conditions the agent asked to be told about while it does something else, written to an events file.
  late final WatchRegistry watches = WatchRegistry(this);

  /// Forwards [ProgressNotification]s to the client; wired by the server.
  void Function(ProgressNotification)? progressNotifier;

  /// `flutter run` processes glint started, keyed by device id, for `kill_app`.
  final Map<String, Process> _launchedApps = {};

  void registerLaunchedApp(String deviceId, Process process) {
    _launchedApps[deviceId] = process;
    _ownedDevices.add(deviceId);
  }

  /// Devices this session attached to or launched on, kept after detach so `shutdown_sim` can tell its own from others'.
  final Set<String> _ownedDevices = {};

  /// Bundle ids / packages of apps this session attached, kept after detach for `kill_app`.
  final Set<String> _ownedAppIds = {};

  bool ownsDevice(String deviceId) => _ownedDevices.contains(deviceId);

  bool ownsApp(String appId) =>
      _ownedAppIds.contains(appId.toLowerCase()) ||
      _pool.values.any((a) => a.bundleId?.toLowerCase() == appId.toLowerCase());

  void markOwnedApp(Iterable<String?> appIds) =>
      _ownedAppIds.addAll(appIds.whereType<String>().map((id) => id.toLowerCase()));

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
  AppSession? get active => _current;

  /// The app this call is bound to via [withApp], else the explicitly activated one.
  AppSession? get _current => (Zone.current[_bindingKey] as AppSession?) ?? _active;

  /// Every attached app, most recently attached first.
  List<AppSession> get apps => _pool.values.toList()..sort((a, b) => b.attachedAt.compareTo(a.attachedAt));

  List<Map<String, Object?>> appsJson() => [for (final a in apps) a.toJson(active: identical(a, _active))];

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

  /// Runs [body] bound to [target] through a zone value, so concurrent calls never see each other's app.
  Future<T> withApp<T>(AppSession target, Future<T> Function() body) =>
      runZoned(body, zoneValues: {_bindingKey: target});

  bool get isAttached => _current != null;
  bool get isDeviceMode => _current?.deviceMode ?? false;

  SceneMode get sceneMode => _current?.sceneMode ?? SceneMode.flutter;
  set sceneMode(SceneMode m) => _current?.sceneMode = m;

  /// Bundle id / package of the active app, when known — used by `kill_app`.
  String? get attachedBundleId => _current?.bundleId;
  set attachedBundleId(String? v) => _current?.bundleId = v;

  int get reconnectCount => _current?.reconnectCount ?? 0;

  AppLogBuffer get appLogs => _current?.appLogs ?? _orphanLogs;

  FlutterRuntime get runtime => _requireAttached(_current?.runtime, 'runtime');
  DeviceTarget get device => _requireAttached(_current?.device, 'device');
  InteractionBackend get backend => _requireAttached(_current?.backend, 'backend');
  InspectorClient get inspector => _requireAttached(_current?.inspector, 'inspector');
  SceneReader get reader => _requireAttached(_current?.reader, 'scene reader');
  CoordinateResolver get resolver => _requireAttached(_current?.resolver, 'resolver');
  Interactor get interactor => _requireAttached(_current?.interactor, 'interactor');
  Semanticizer get semanticizer => _requireAttached(_current?.semanticizer, 'semanticizer');
  OverlayEnricher get overlayEnricher => _requireAttached(_current?.overlayEnricher, 'overlay enricher');
  InputEnricher get inputEnricher => _requireAttached(_current?.inputEnricher, 'input enricher');
  ToggleEnricher get toggleEnricher => _requireAttached(_current?.toggleEnricher, 'toggle enricher');
  SemanticsFlagEnricher get flagEnricher => _requireAttached(_current?.flagEnricher, 'flag enricher');
  ButtonFactsEnricher get buttonEnricher => _requireAttached(_current?.buttonEnricher, 'button enricher');
  InertEnricher get inertEnricher => _requireAttached(_current?.inertEnricher, 'inert enricher');
  OpaqueWidgetEnricher get opaqueEnricher => _requireAttached(_current?.opaqueEnricher, 'opaque widget enricher');
  TabLabelEnricher get tabEnricher => _requireAttached(_current?.tabEnricher, 'tab enricher');
  ImageEnricher get imageEnricher => _requireAttached(_current?.imageEnricher, 'image enricher');
  MapEnricher get mapEnricher => _requireAttached(_current?.mapEnricher, 'map enricher');
  IconEnricher get iconEnricher => _requireAttached(_current?.iconEnricher, 'icon enricher');
  LinkEnricher get linkEnricher => _requireAttached(_current?.linkEnricher, 'link enricher');
  NavigationEnricher get navEnricher => _requireAttached(_current?.navEnricher, 'nav enricher');
  PagedViewportEnricher get pagedEnricher => _requireAttached(_current?.pagedEnricher, 'paged enricher');
  ReadinessGate get readinessGate => _requireAttached(_current?.readinessGate, 'readiness gate');
  SettleDetector get settleDetector => _requireAttached(_current?.settleDetector, 'settle detector');

  /// Null when the active device is not an iOS simulator.
  NativeReader? get nativeReader => _current?.nativeReader;

  // ── lifecycle ─────────────────────────────────────────────────────────────

  /// Attach (or switch to) the app at [vmUri] on [device]. A pooled session
  /// bound to the same VM is activated as-is; a different app on the same
  /// device replaces the old entry. Other pooled apps stay connected.
  /// [rebuild] replaces even a live session of the same app, to move it to another input backend.
  Future<AppSession> attach({
    required Uri vmUri,
    required DeviceTarget device,
    bool rebuild = false,
  }) async {
    final existing = _pool[device.id];
    if (!rebuild && existing != null && !existing.deviceMode && existing.vmUri == vmUri && existing.isLive) {
      _active = existing;
      return existing;
    }
    if (existing != null) await _drop(existing);
    final key = _vmKey(vmUri);
    final retained = _retainedLogs.where((r) => r.key == key).firstOrNull;
    final app = await AppSession.connect(
      vmUri: vmUri,
      device: device,
      runtimeFactory: _runtimeFactory,
      appLogCapacity: config.appLogCapacity,
      showTouches: config.showTouches,
      appLogs: retained?.buffer,
    );
    _retainedLogs.remove(retained);
    _noteLostLogs(device.id, vmUri);
    app.captureSettleMs = config.captureSettleMs;
    _pool[device.id] = app;
    _ownedDevices.add(device.id);
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
    _ownedDevices.add(device.id);
    _active = app;
    return app;
  }

  /// Applies `config.showTouches` to every live Flutter app, and to device-mode Android emulators, which draw touches themselves; other device-mode apps are skipped.
  Future<Map<AppSession, TouchesOutcome>> applyShowTouches() async => {
        for (final app in apps)
          if (app.isLive && (!app.deviceMode || app.device is AndroidDevice))
            app: await app.setShowTouches(config.showTouches),
      };

  /// Detach one app (the active one by default) and drop it from the pool.
  /// When exactly one other app remains it becomes active.
  Future<void> detach({String? deviceId}) async {
    final target = deviceId != null ? _pool[deviceId] : _active;
    if (target == null) return;
    await _drop(target);
    DeviceClaims().release(target.id);
    if (_active == null && _pool.length == 1) _active = _pool.values.single;
  }

  Future<void> detachAll() async {
    for (final app in _pool.values.toList()) {
      await _drop(app);
      DeviceClaims().release(app.id);
    }
  }

  static String _vmKey(Uri vmUri) => '${vmUri.host}:${vmUri.port}${vmUri.path.replaceFirst(RegExp(r'/+$'), '')}';

  void _retainLogs(AppSession app) {
    final vmUri = app.vmUri;
    if (app.deviceMode || vmUri == null || app.appLogs.nextSequence == 0) return;
    _retainedLogs
      ..removeWhere((r) => r.key == _vmKey(vmUri))
      ..add(_RetainedLogs(app.id, _vmKey(vmUri), app.appLogs));
    while (_retainedLogs.length > _retainedLogLimit) {
      _retainedLogs.removeAt(0);
    }
  }

  void _noteLostLogs(String deviceId, Uri vmUri) {
    final stale = _retainedLogs.where((r) => r.deviceId == deviceId && r.key != _vmKey(vmUri)).toList();
    if (stale.isEmpty) return;
    _retainedLogs.removeWhere(stale.contains);
    final lost = stale.fold(0, (n, r) => n + r.buffer.length);
    _logNotes[deviceId] = 'app_logs restarted empty: the $lost earlier log entries belonged to a different app '
        'process on this device (new VM service $vmUri). Read them before re-attaching next time.';
  }

  Future<void> _drop(AppSession app) async {
    _pool.remove(app.id);
    watches.appDropped(app);
    _retainLogs(app);
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
    final semantic = semanticizer.semanticize(scene, imageCandidates: true);
    // Overlay first so overlayLayers is populated before anything renders;
    // the rest are order-independent.
    await overlayEnricher.enrich(semantic);
    await navEnricher.enrich(semantic);
    await pagedEnricher.enrich(semantic);
    if (detail == SceneDetail.structural) {
      ImageEnricher.dropCandidates(semantic);
    } else {
      await inputEnricher.enrich(semantic);
      await toggleEnricher.enrich(semantic);
      await flagEnricher.enrich(semantic);
      await tabEnricher.enrich(semantic);
      await opaqueEnricher.enrich(semantic);
      await buttonEnricher.enrich(semantic);
      await imageEnricher.enrich(semantic);
    }
    if (detail == SceneDetail.full) {
      await iconEnricher.enrich(semantic);
      await linkEnricher.enrich(semantic);
      await mapEnricher.enrich(semantic);
    }
    if (detail != SceneDetail.structural) await inertEnricher.enrich(semantic);
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
    final orientation = aspect == 0 ? null : (aspect > 1 ? 'landscape' : 'portrait');
    final brightness = parts.length > 3 && parts[3].isNotEmpty ? parts[3] : null;
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
    final s = await runtime.evaluateString('WidgetsBinding.instance.lifecycleState?.name ?? ""');
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Text of the focused EditableText, or null when no text field has focus. A leading "1" marker separates "no field" (empty) from "focused but empty" ("1").
  Future<String?> focusedFieldText() async {
    final raw = await runtime.evaluateString(
      '(FocusManager.instance.primaryFocus?.context'
      '?.findAncestorStateOfType<EditableTextState>() == null'
      ' ? "" : "1" + FocusManager.instance.primaryFocus!.context!'
      '.findAncestorStateOfType<EditableTextState>()!.textEditingValue.text)',
    );
    return (raw == null || raw.isEmpty) ? null : raw.substring(1);
  }

  /// The focused field's text, and whether its own input formatters may rewrite what is typed (the newline filter every single-line field gets does not count); null when no text field has focus.
  Future<({String text, bool formatted})?> focusedFieldInfo() async {
    const state = 'FocusManager.instance.primaryFocus!.context!.findAncestorStateOfType<EditableTextState>()!';
    final raw = await runtime.evaluateString(
      '(FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() == null ? "" : '
      '(($state.widget.inputFormatters ?? const []).any((f) { try { return (f as dynamic).filterPattern != "\\n"; } catch (_) { return true; } }) ? "f" : "p") + '
      '$state.textEditingValue.text)',
    );
    return (raw == null || raw.isEmpty) ? null : (text: raw.substring(1), formatted: raw[0] == 'f');
  }

  /// Logical viewport size + DPR, probed via geometry resolver on any
  /// addressable node. Used by direction-based scroll tools.
  Future<({double logicalW, double logicalH, double dpr})> probeViewport() async {
    final scene = await reader.readSummary();
    try {
      return await viewportIn(scene);
    } finally {
      await scene.dispose();
    }
  }

  /// [probeViewport] against a scene the caller already holds. The implicit
  /// view answers without a node; a selected node is the fallback.
  Future<({double logicalW, double logicalH, double dpr})> viewportIn(Scene scene) async {
    try {
      final v = await resolver.resolveViewportNodeFree();
      return (logicalW: v.w, logicalH: v.h, dpr: v.dpr);
    } on GeometryResolveError {
      // fall back to a node-anchored probe below
    }
    final probeId = scene.firstAddressableId();
    if (probeId == null) {
      throw GeometryResolveError('no addressable node in scene to probe viewport from');
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
  Future<ScrollAnchor?> probeScrollAnchor() async {
    final scene = await reader.readSummary();
    try {
      return await scrollAnchorIn(scene, semanticizer.semanticize(scene));
    } finally {
      await scene.dispose();
    }
  }

  /// [probeScrollAnchor] against a scene + semantic view the caller holds; the anchor is scrolled content, never the viewport itself, whose center stays put.
  Future<ScrollAnchor?> scrollAnchorIn(Scene scene, SemanticScene semantic) async {
    final list = semantic.root.walk().whereType<SemanticList>().firstOrNull;
    return list == null ? null : _anchorWithin(scene, list);
  }

  /// The anchor of the innermost scrollable whose viewport contains logical point [x], [y]; null when the point is over no scrollable.
  Future<ScrollAnchor?> scrollAnchorAt(Scene scene, SemanticScene semantic, double x, double y) async {
    ScrollAnchor? best;
    var bestArea = double.infinity;
    for (final list in semantic.root.walk().whereType<SemanticList>()) {
      final anchor = await _anchorWithin(scene, list);
      final clip = anchor?.clip;
      if (anchor == null || clip == null) continue;
      final contains = x >= clip.x && x <= clip.x + clip.w && y >= clip.y && y <= clip.y + clip.h;
      if (contains && clip.w * clip.h < bestArea) {
        best = anchor;
        bestArea = clip.w * clip.h;
      }
    }
    return best;
  }

  /// The first resolvable descendant of [list], tried from the middle outward since pinned headers and footers sit at the ends and never move with the content.
  Future<ScrollAnchor?> _anchorWithin(Scene scene, SemanticList list) async {
    final ids = [
      for (final n in list.walk())
        if (n.glintId != null && !identical(n, list)) n.glintId!,
    ];
    for (final id in _middleOut(ids)) {
      try {
        final c = await resolver.resolve(scene, id);
        if (c.hasNonZeroBounds) {
          return (glintId: id, x: c.logicalCenter.x, y: c.logicalCenter.y, clip: c.clip);
        }
      } on Object {
        // unresolvable node — try the next descendant
      }
    }
    return null;
  }

  /// [path] shrunk for the model per the screenshot settings, with how its pixels map to `tap x,y`; [maxSize] overrides the configured cap.
  Future<({ModelImage image, String coordinates})> modelImage(String path, {int? maxSize}) async {
    final size = pngSize(path);
    if (size == null) {
      return (
        image: (path: path, width: 0, height: 0, mimeType: 'image/png'),
        coordinates: 'image size unknown; tap x,y in logical points',
      );
    }
    final (w, h) = size;
    final image = await prepareModelImage(path,
        width: w,
        height: h,
        maxSize: maxSize ?? config.screenshotMaxSize,
        format: config.screenshotFormat,
        quality: config.screenshotQuality);
    final device = isDeviceMode;
    final target = device ? w.toDouble() : w / this.device.devicePixelRatio;
    final factor = image.width == 0 ? 1.0 : target / image.width;
    return (
      image: image,
      coordinates: 'image is ${image.width}x${image.height}; tap x,y in '
          '${device ? 'screen pixels' : 'logical points'} = image pixel × '
          '${factor.toStringAsFixed(3)}',
    );
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
  String toString() => 'glint session is not attached; call `attach` before using `$missing`';
}

/// [items] starting at the middle and alternating outward.
Iterable<T> _middleOut<T>(List<T> items) sync* {
  final mid = items.length ~/ 2;
  for (var d = 0; d <= items.length; d++) {
    if (mid - d >= 0 && mid - d < items.length) yield items[mid - d];
    if (d > 0 && mid + d < items.length) yield items[mid + d];
  }
}

class _RetainedLogs {
  _RetainedLogs(this.deviceId, this.key, this.buffer);
  final String deviceId;
  final String key;
  final AppLogBuffer buffer;
}
