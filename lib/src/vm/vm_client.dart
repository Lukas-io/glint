import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// VM-service connection scoped to the first Flutter isolate.
class VmClient {
  VmService? _service;
  Uri? _connectedUri;
  Isolate? _flutterIsolate;

  bool get isConnected => _service != null;
  Uri? get connectedUri => _connectedUri;

  VmService get service =>
      _service ?? (throw StateError('VM service is not connected.'));

  Isolate get flutterIsolate => _flutterIsolate ??
      (throw StateError('No Flutter isolate selected. Call attach() first.'));

  String get flutterIsolateId => flutterIsolate.id!;

  Future<void> attach(Uri vmServiceUri) async {
    if (_service != null) await disconnect();
    final svc = await vmServiceConnectUri(_toWs(vmServiceUri));
    // Zombie-DDS probe: a stale DDS accepts the WS upgrade but never answers
    // RPCs. 5s deadline fails fast with a clear error.
    try {
      await svc.getVersion().timeout(const Duration(seconds: 5));
    } on Object {
      await svc.dispose();
      throw StateError(
        'VM service at $vmServiceUri accepted the connection but did not '
        'respond to getVersion() within 5s. The DDS instance is likely '
        'stale — restart the Flutter app to spawn a fresh one.',
      );
    }
    _service = svc;
    _connectedUri = vmServiceUri;
    await _selectFlutterIsolate();
  }

  Future<void> _selectFlutterIsolate() async {
    final vm = await service.getVM();
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      final iso = await service.getIsolate(id);
      final rpcs = iso.extensionRPCs ?? const <String>[];
      if (rpcs.any((e) => e.startsWith('ext.flutter.'))) {
        _flutterIsolate = iso;
        return;
      }
    }
    throw StateError(
      'No isolate exposes ext.flutter.* extensions. Is the target a Flutter '
      'app running in debug mode?',
    );
  }

  Future<void> disconnect() async {
    final svc = _service;
    _service = null;
    _flutterIsolate = null;
    _connectedUri = null;
    if (svc != null) await svc.dispose();
  }

  static String _toWs(Uri uri) {
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri.toString();
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
    if (segments.isEmpty || segments.last != 'ws') segments.add('ws');
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.port,
      pathSegments: segments,
    ).toString();
  }
}
