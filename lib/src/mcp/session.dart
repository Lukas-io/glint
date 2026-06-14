import '../../interaction.dart';
import '../../observability.dart';
import '../../perception.dart';
import '../../semantic.dart';
import '../runtime/flutter_runtime.dart';
import '../runtime/vm_service_runtime.dart';

/// Per-connection state: runtime, device, readers, interactor. Tools
/// access these via the typed getters; accessing before [attach] throws
/// [SessionNotAttachedError]. [actionLog] is always available — survives
/// detach so cross-attach history stays queryable.
class GlintSession {
  GlintSession({
    GlintConfig? config,
    UsageRecorder? usage,
    FlutterRuntime Function()? runtimeFactory,
  })  : config = config ?? GlintConfig(),
        actionLog = ActionLog(),
        appLogs = AppLogBuffer(),
        sessions = SessionManager(),
        usage = usage ?? UsageRecorder.fromEnv(),
        _runtimeFactory = runtimeFactory ?? VmServiceRuntime.new {
    usageReporter = UsageReporter(this.usage);
  }

  final GlintConfig config;
  final ActionLog actionLog;
  final AppLogBuffer appLogs;
  final SessionManager sessions;
  final UsageRecorder usage;
  late final UsageReporter usageReporter;
  final FlutterRuntime Function() _runtimeFactory;

  FlutterRuntime? _runtime;
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

  bool get isAttached => _runtime != null;

  FlutterRuntime get runtime => _requireAttached(_runtime, 'runtime');
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
    if (_runtime != null) await detach();

    final runtime = _runtimeFactory();
    await runtime.attach(vmUri);

    final inspector = InspectorClient(runtime);
    final reader = SceneReader(inspector);
    final resolver = CoordinateResolver(runtime);
    final backend = device.createBackend();
    final interactor = Interactor(backend: backend, resolver: resolver);
    final semanticizer = Semanticizer();
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
    _inputEnricher = inputEnricher;
    _iconEnricher = iconEnricher;
    _navEnricher = navEnricher;
    _readinessGate = readinessGate;
    _settleDetector = settleDetector;
    // Hook app log buffer onto the new runtime's streams.
    try {
      await appLogs.subscribe(runtime);
    } on Object {
      // app logs stay empty; everything else works
    }
  }

  /// Focused widget runtime type + keyboard inset + orientation +
  /// brightness + locale in one VM eval. ~50ms.
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

  /// One of: resumed, inactive, paused, detached, hidden. Null when the
  /// binding hasn't set a state yet.
  Future<String?> lifecycleState() async {
    final s = await runtime
        .evaluateString('WidgetsBinding.instance.lifecycleState?.name ?? ""');
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Logical viewport size + dpr in physical pixels, probed via the
  /// geometry resolver on any addressable node. Used by direction-based
  /// scroll tools that need a "scroll N% of viewport" delta.
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
    final runtime = _runtime;
    _runtime = null;
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
    if (runtime != null) await runtime.disconnect();
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
