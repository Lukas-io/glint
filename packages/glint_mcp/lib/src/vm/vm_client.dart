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

  /// Waits for an isolate with a widget tree; a restarted app may take seconds of start-up work before its UI isolate builds one, while a background engine's isolate is already there.
  Future<void> _reselectUntilFound({String? exclude}) async {
    final deadline = DateTime.now().add(reselectTimeout);
    while (true) {
      try {
        final withTree = await _selectFlutterIsolate(exclude: exclude);
        if (withTree || DateTime.now().isAfter(deadline)) return;
      } on StateError {
        if (_service == null || DateTime.now().isAfter(deadline)) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Longest a hot restart may take to bring up a new Flutter isolate with its widget tree.
  static const reselectTimeout = Duration(seconds: 15);

  void _onIsolateEvent(Event e) {
    final id = e.isolate?.id;
    final current = _flutterIsolate?.id;
    final replaced = e.kind == EventKind.kIsolateExit && id == current;
    final newFlutter = e.kind == EventKind.kServiceExtensionAdded &&
        id != current &&
        (e.extensionRPC ?? '').startsWith('ext.flutter.inspector.');
    if (replaced) unawaited(reselect().catchError((_) {}));
    // A background engine (push or workmanager handler) registers the same extensions; only move when the current isolate is gone or has no widget tree.
    if (newFlutter) unawaited(_reselectIfCurrentLacksTree());
  }

  Future<void> _reselectIfCurrentLacksTree() async {
    final current = _flutterIsolate?.id;
    if (current == null || _service == null) return;
    try {
      await service.getIsolate(current).timeout(const Duration(seconds: 2));
    } on SentinelException {
      await reselect().catchError((_) {});
      return;
    } on Object {
      return;
    }
    if (await _treeReady(current) != true) await reselect().catchError((_) {});
  }

  /// Whether [isolateId] has built its widget tree: the UI isolate has, a background engine's has not; null when it does not answer.
  Future<bool?> _treeReady(String isolateId) async {
    try {
      final resp = await service
          .callServiceExtension('ext.flutter.inspector.isWidgetTreeReady', isolateId: isolateId)
          .timeout(const Duration(seconds: 2));
      final result = resp.json?['result'];
      return result is bool ? result : null;
    } on Object {
      return null;
    }
  }

  /// Longest one VM read may take during attach; a suspended app (device locked) never answers.
  static const readTimeout = Duration(seconds: 8);

  /// Picks the Flutter isolate, preferring one whose widget tree is built, then the one named main; true when the pick has a widget tree.
  Future<bool> _selectFlutterIsolate({String? exclude}) async {
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
      final ready = <Isolate>[
        for (final c in candidates)
          if (await _treeReady(c.id!) == true) c,
      ];
      final pool = ready.isNotEmpty ? ready : candidates;
      _flutterIsolate = pool.firstWhere((i) => i.name == 'main', orElse: () => pool.first);
      return ready.isNotEmpty;
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
