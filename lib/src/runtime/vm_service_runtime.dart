import 'package:vm_service/vm_service.dart';

import '../vm/vm_client.dart';
import 'flutter_runtime.dart';

/// The default [FlutterRuntime] backed by `package:vm_service`. Owns one
/// [VmClient] and centralises every `ext.flutter.inspector.*` and
/// `evaluate` call site.
class VmServiceRuntime implements FlutterRuntime {
  VmServiceRuntime({VmClient? client}) : _vm = client ?? VmClient();

  final VmClient _vm;

  @override
  bool get isAttached => _vm.isConnected;

  @override
  Uri? get attachedUri => _vm.connectedUri;

  @override
  VmService get rawService => _vm.service;

  @override
  String get flutterIsolateId => _vm.flutterIsolateId;

  String? get _rootLibId => _vm.flutterIsolate.rootLib?.id;

  @override
  Future<void> attach(Uri vmServiceUri) async {
    await _vm.attach(vmServiceUri);
    // Subscribe to event streams once; broadcast getters share the
    // single subscription with all downstream consumers.
    for (final stream in const [
      EventStreams.kStderr,
      EventStreams.kStdout,
      EventStreams.kLogging,
    ]) {
      try {
        await _vm.service.streamListen(stream);
      } on Object {
        // already listening — fine
      }
    }
  }

  @override
  Future<void> disconnect() => _vm.disconnect();

  // ── inspector ─────────────────────────────────────────────────────

  @override
  Future<InspectorJson> readWidgetTree({
    required String groupName,
    bool isSummaryTree = true,
    bool withPreviews = true,
    bool fullDetails = false,
  }) async {
    final resp = await _vm.service.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: flutterIsolateId,
      args: {
        'groupName': groupName,
        'isSummaryTree': isSummaryTree.toString(),
        'withPreviews': withPreviews.toString(),
        'fullDetails': fullDetails.toString(),
      },
    );
    final result = (resp.json?['result'] as Map?)?.cast<String, Object?>();
    if (result == null) {
      throw RuntimeEvalError(
        'getRootWidgetTree',
        'response missing `result` map: ${resp.json}',
      );
    }
    return result;
  }

  @override
  Future<InspectorJson> readDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) async {
    final resp = await _vm.service.callServiceExtension(
      'ext.flutter.inspector.getDetailsSubtree',
      isolateId: flutterIsolateId,
      args: {
        'arg': inspectorId,
        'objectGroup': groupName,
        'subtreeDepth': subtreeDepth.toString(),
      },
    );
    final result = (resp.json?['result'] as Map?)?.cast<String, Object?>();
    if (result == null) {
      throw RuntimeEvalError(
        'getDetailsSubtree',
        'response missing `result` map: ${resp.json}',
      );
    }
    return result;
  }

  @override
  Future<void> setInspectorSelection({
    required String inspectorId,
    required String groupName,
  }) async {
    await _vm.service.callServiceExtension(
      'ext.flutter.inspector.setSelectionById',
      isolateId: flutterIsolateId,
      args: {'arg': inspectorId, 'objectGroup': groupName},
    );
  }

  @override
  Future<void> disposeInspectorGroup(String groupName) async {
    try {
      await _vm.service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: flutterIsolateId,
        args: {'groupName': groupName},
      );
    } on Object {
      // best-effort
    }
  }

  // ── evaluation ────────────────────────────────────────────────────

  @override
  Future<InstanceRef> evaluate(String expression) async {
    final rootLib = _rootLibId;
    if (rootLib == null) {
      throw RuntimeEvalError(expression, 'flutter isolate has no rootLib');
    }
    final raw =
        await _vm.service.evaluate(flutterIsolateId, rootLib, expression);
    if (raw is InstanceRef) return raw;
    if (raw is ErrorRef) {
      throw RuntimeEvalError(expression, raw.message ?? 'ErrorRef');
    }
    throw RuntimeEvalError(
      expression,
      'unexpected eval return ${raw.runtimeType}',
    );
  }

  @override
  Future<String?> evaluateString(String expression) async {
    final InstanceRef raw;
    try {
      raw = await evaluate(expression);
    } on RuntimeEvalError {
      return null;
    }
    final s = raw.valueAsString;
    if (s == null) return null;
    if (raw.valueAsStringIsTruncated != true) return s;
    // Refetch the full value — Pixel 8 logical viewport 411.428…
    // pushed geometry JSON past the 128-char preview.
    final id = raw.id;
    if (id == null) return s;
    final full = await _vm.service.getObject(flutterIsolateId, id);
    if (full is Instance && full.valueAsString != null) {
      return full.valueAsString;
    }
    return s;
  }

  // ── streams ───────────────────────────────────────────────────────

  @override
  Stream<Event> get stderrEvents => _vm.service.onStderrEvent;

  @override
  Stream<Event> get stdoutEvents => _vm.service.onStdoutEvent;

  @override
  Stream<Event> get loggingEvents => _vm.service.onLoggingEvent;
}
