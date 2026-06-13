import '../../interaction.dart';
import '../../perception.dart';
import '../../semantic.dart';

/// Per-connection state: VM client, device, readers, interactor.
/// Tools access these via the typed getters; accessing before
/// [attach] throws [SessionNotAttachedError].
class GlintSession {
  GlintSession();

  VmClient? _vm;
  DeviceTarget? _device;
  InteractionBackend? _backend;
  SceneReader? _reader;
  CoordinateResolver? _resolver;
  Interactor? _interactor;
  Semanticizer? _semanticizer;

  bool get isAttached => _vm != null;

  VmClient get vm => _requireAttached(_vm, 'vm client');
  DeviceTarget get device => _requireAttached(_device, 'device');
  InteractionBackend get backend => _requireAttached(_backend, 'backend');
  SceneReader get reader => _requireAttached(_reader, 'scene reader');
  CoordinateResolver get resolver => _requireAttached(_resolver, 'resolver');
  Interactor get interactor => _requireAttached(_interactor, 'interactor');
  Semanticizer get semanticizer => _requireAttached(_semanticizer, 'semanticizer');

  /// Idempotent — re-attach replaces the previous connection.
  Future<void> attach({
    required Uri vmUri,
    required DeviceTarget device,
  }) async {
    if (_vm != null) await detach();

    final vm = VmClient();
    await vm.attach(vmUri);

    final reader = SceneReader(InspectorClient(vm));
    final resolver = CoordinateResolver(vm);
    final backend = device.createBackend();
    final interactor = Interactor(backend: backend, resolver: resolver);
    final semanticizer = Semanticizer();

    _vm = vm;
    _device = device;
    _backend = backend;
    _reader = reader;
    _resolver = resolver;
    _interactor = interactor;
    _semanticizer = semanticizer;
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
    final vm = _vm;
    _vm = null;
    _device = null;
    _backend = null;
    _reader = null;
    _resolver = null;
    _interactor = null;
    _semanticizer = null;
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
