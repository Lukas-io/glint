import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// VM-service connection scoped to the first Flutter isolate.
class VmClient {
  VmService? _service;
  Uri? _connectedUri;
  Isolate? _flutterIsolate;
  Future<void>? _reselecting;
  StreamSubscription<Event>? _isolateEvents;

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
    _isolateEvents = svc.onIsolateEvent.listen(_onIsolateEvent);
    try {
      await svc.streamListen(EventStreams.kIsolate);
    } on Object {
      // already subscribed or unsupported; the sentinel retry still re-selects
    }
  }

  /// Resolves once any in-flight isolate re-selection has finished.
  Future<void> ready() => _reselecting ?? Future.value();

  /// Picks the Flutter isolate again, e.g. after a hot restart replaced it; concurrent callers share one attempt.
  Future<void> reselect() => _reselecting ??=
      _reselectUntilFound(exclude: _flutterIsolate?.id)
          .whenComplete(() => _reselecting = null);

  Future<void> _reselectUntilFound({String? exclude}) async {
    final deadline = DateTime.now().add(reselectTimeout);
    while (true) {
      try {
        await _selectFlutterIsolate(exclude: exclude);
        return;
      } on StateError {
        if (_service == null || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Longest a hot restart may take to bring up a new Flutter isolate.
  static const reselectTimeout = Duration(seconds: 5);

  void _onIsolateEvent(Event e) {
    final id = e.isolate?.id;
    final current = _flutterIsolate?.id;
    final replaced = e.kind == EventKind.kIsolateExit && id == current;
    final newFlutter = e.kind == EventKind.kServiceExtensionAdded &&
        id != current &&
        (e.extensionRPC ?? '').startsWith('ext.flutter.inspector.');
    if (replaced || newFlutter) unawaited(reselect().catchError((_) {}));
  }

  Future<void> _selectFlutterIsolate({String? exclude}) async {
    final vm = await service.getVM();
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null || id == exclude) continue;
      final Isolate iso;
      try {
        iso = await service.getIsolate(id);
      } on SentinelException {
        continue;
      }
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
    await _isolateEvents?.cancel();
    _isolateEvents = null;
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
