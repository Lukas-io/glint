import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Thin VM-service connection.
///
/// Connects to a Dart VM by URI, picks the Flutter isolate (the first one
/// that exposes any `ext.flutter.*` extension), and exposes the raw
/// [VmService] plus the resolved [Isolate]/`isolateId` to callers.
///
/// Patterns ported from `flutter_network_mcp/lib/src/vm/vm_client.dart`:
/// the zombie-DTD probe (5s deadline on `getVersion`) and the WS-URI
/// normalisation. Stripped of the HTTP/socket profiling concern — Module
/// B only needs raw service-extension calls.
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
