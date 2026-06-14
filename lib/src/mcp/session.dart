import 'package:vm_service/vm_service.dart';

import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';

/// Per-connection state: VM client, device, readers, interactor.
/// Tools access these via the typed getters; accessing before
/// [attach] throws [SessionNotAttachedError]. [actionLog] is always
/// available — survives detach so cross-attach history stays queryable.
class GlintSession {
  GlintSession({GlintConfig? config, UsageRecorder? usage})
      : config = config ?? GlintConfig(),
        actionLog = ActionLog(),
        appLogs = AppLogBuffer(),
        sessions = SessionManager(),
        usage = usage ?? UsageRecorder.fromEnv() {
    usageReporter = UsageReporter(this.usage);
  }

  final GlintConfig config;
  final ActionLog actionLog;
  final AppLogBuffer appLogs;
  final SessionManager sessions;
  final UsageRecorder usage;
  late final UsageReporter usageReporter;

  VmClient? _vm;
  DeviceTarget? _device;
  InteractionBackend? _backend;
  InspectorClient? _inspector;
  SceneReader? _reader;
  CoordinateResolver? _resolver;
  Interactor? _interactor;
  Semanticizer? _semanticizer;
  InputEnricher? _inputEnricher;
  IconEnricher? _iconEnricher;
  NavigationEnricher? _navEnricher;
  ReadinessGate? _readinessGate;
  SettleDetector? _settleDetector;

  bool get isAttached => _vm != null;

  VmClient get vm => _requireAttached(_vm, 'vm client');
  DeviceTarget get device => _requireAttached(_device, 'device');
  InteractionBackend get backend => _requireAttached(_backend, 'backend');
  InspectorClient get inspector => _requireAttached(_inspector, 'inspector');
  SceneReader get reader => _requireAttached(_reader, 'scene reader');
  CoordinateResolver get resolver => _requireAttached(_resolver, 'resolver');
  Interactor get interactor => _requireAttached(_interactor, 'interactor');
  Semanticizer get semanticizer => _requireAttached(_semanticizer, 'semanticizer');
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

  /// Idempotent — re-attach replaces the previous connection.
  Future<void> attach({
    required Uri vmUri,
    required DeviceTarget device,
  }) async {
    if (_vm != null) await detach();

    final vm = VmClient();
    await vm.attach(vmUri);

    final inspector = InspectorClient(vm);
    final reader = SceneReader(inspector);
    final resolver = CoordinateResolver(vm);
    final backend = device.createBackend();
    final interactor = Interactor(backend: backend, resolver: resolver);
    final semanticizer = Semanticizer();
    final inputEnricher = InputEnricher(vm: vm, inspector: inspector);
    final iconEnricher = IconEnricher(vm: vm);
    final navEnricher = NavigationEnricher(vm: vm);
    final readinessGate = ReadinessGate(reader: reader, resolver: resolver);
    final settleDetector = SettleDetector(vm: vm, reader: reader);

    _vm = vm;
    _device = device;
    _backend = backend;
    _inspector = inspector;
    _reader = reader;
    _resolver = resolver;
    _interactor = interactor;
    _semanticizer = semanticizer;
    _inputEnricher = inputEnricher;
    _iconEnricher = iconEnricher;
    _navEnricher = navEnricher;
    _readinessGate = readinessGate;
    _settleDetector = settleDetector;
    // Wire the app log buffer to the new VM. Best-effort: a stream
    // subscription failure shouldn't fail attach.
    try {
      await appLogs.subscribe(vm);
    } on Object {
      // app logs stay empty; everything else works
    }
  }

  /// Logical viewport size + dpr in physical pixels, probed via the
  /// geometry resolver on any addressable node. Used by direction-based
  /// scroll tools that need a "scroll N% of viewport" delta.
  /// Focused widget runtime type + keyboard inset + orientation +
  /// brightness + locale, in one VM eval. ~50ms.
  Future<
      ({
        String? focusedType,
        double keyboardBottomPx,
        String? orientation,
        String? brightness,
        String? locale,
      })> uiState() async {
    final svc = vm.service;
    final isolateId = vm.flutterIsolateId;
    final rootLib = vm.flutterIsolate.rootLib?.id;
    const empty = (
      focusedType: null,
      keyboardBottomPx: 0.0,
      orientation: null,
      brightness: null,
      locale: null,
    );
    if (rootLib == null) return empty;
    try {
      final raw = await svc.evaluate(
        isolateId,
        rootLib,
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
      if (raw is! InstanceRef || raw.valueAsString == null) return empty;
      final parts = raw.valueAsString!.split('|');
      final focusedType = parts[0].isEmpty ? null : parts[0];
      final kb = parts.length > 1 ? double.tryParse(parts[1]) ?? 0.0 : 0.0;
      final aspect = parts.length > 2 ? double.tryParse(parts[2]) ?? 0 : 0;
      final orientation = aspect == 0 ? null : (aspect > 1 ? 'landscape' : 'portrait');
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
    } on Object {
      return empty;
    }
  }

  /// Reads the current Flutter app lifecycle state via VM eval. Returns
  /// one of: resumed, inactive, paused, detached, hidden, or null when
  /// the binding hasn't been set yet. Cheap single eval (~50ms).
  Future<String?> lifecycleState() async {
    final svc = vm.service;
    final isolateId = vm.flutterIsolateId;
    final rootLib = vm.flutterIsolate.rootLib?.id;
    if (rootLib == null) return null;
    try {
      final raw = await svc.evaluate(
        isolateId,
        rootLib,
        'WidgetsBinding.instance.lifecycleState?.name ?? ""',
      );
      if (raw is! InstanceRef || raw.valueAsString == null) return null;
      final s = raw.valueAsString!;
      return s.isEmpty ? null : s;
    } on Object {
      return null;
    }
  }

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

  Future<void> detach() async {
    await appLogs.unsubscribe();
    final vm = _vm;
    _vm = null;
    _device = null;
    _backend = null;
    _inspector = null;
    _reader = null;
    _resolver = null;
    _interactor = null;
    _semanticizer = null;
    _inputEnricher = null;
    _iconEnricher = null;
    _navEnricher = null;
    _readinessGate = null;
    _settleDetector = null;
    if (vm != null) await vm.disconnect();
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
