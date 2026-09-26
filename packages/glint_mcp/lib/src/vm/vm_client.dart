import 'package:glint_core/glint_core.dart' show connectVmService;
import 'dart:async';

import 'package:vm_service/vm_service.dart';

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
    final svc = await connectVmService(vmServiceUri, connectTimeout: readTimeout);
    _service = svc;
    _connectedUri = vmServiceUri;
    await _selectFlutterIsolate();
    _isolateEvents = svc.onIsolateEvent.listen(_onIsolateEvent);
    try {
      await svc.streamListen(EventStreams.kIsolate).timeout(readTimeout);
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
    if (replaced) unawaited(reselect().catchError((_) {}));
    // A background engine (push or workmanager handler) registers the same extensions; only follow it once the UI isolate is gone.
    if (newFlutter) unawaited(_reselectIfCurrentGone());
  }

  Future<void> _reselectIfCurrentGone() async {
    final current = _flutterIsolate?.id;
    if (current == null || _service == null) return;
    try {
      await service.getIsolate(current).timeout(const Duration(seconds: 2));
    } on SentinelException {
      await reselect().catchError((_) {});
    } on Object {
      // still there, or unreachable for now: keep it
    }
  }

  /// Longest one VM read may take during attach; a suspended app (device locked) never answers.
  static const readTimeout = Duration(seconds: 8);

  Future<void> _selectFlutterIsolate({String? exclude}) async {
    final vm = await service.getVM().timeout(readTimeout);
    final candidates = <Isolate>[];
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null || id == exclude) continue;
      final Isolate iso;
      try {
        iso = await service.getIsolate(id).timeout(readTimeout);
      } on SentinelException {
        continue;
      }
      final rpcs = iso.extensionRPCs ?? const <String>[];
      if (rpcs.any((e) => e.startsWith('ext.flutter.'))) candidates.add(iso);
    }
    if (candidates.isNotEmpty) {
      // The UI isolate is named main; background engines get other names.
      _flutterIsolate = candidates.firstWhere((i) => i.name == 'main',
          orElse: () => candidates.first);
      return;
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

}
