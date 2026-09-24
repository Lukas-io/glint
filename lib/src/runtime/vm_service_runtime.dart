import 'dart:async';

import 'package:vm_service/vm_service.dart';

import '../vm/vm_client.dart';
import 'flutter_runtime.dart';
import 'inspector_params.dart';

// RPCError code emitted by vm_service when the WebSocket connection drops.
const _kConnectionClosedCode = 100;

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

  String? _evalLibId;
  String? _evalLibIsolateId;

  /// Framework libraries whose imports cover every glint expression; tried before the app's own so an app entry that never imports Flutter still works.
  static const frameworkEvalLibraries = [
    'package:flutter/src/material/text_field.dart',
    'package:flutter/src/cupertino/text_field.dart',
    'package:flutter/src/widgets/widget_inspector.dart',
  ];

  /// Compiles only where every Flutter name glint's expressions use is in scope.
  static const scopeCanary = '[WidgetsBinding, WidgetInspectorService, View, '
      'FocusManager, EditableText, EditableTextState, ModalRoute, Offstage, '
      'Visibility, Opacity, AbsorbPointer, IgnorePointer, Icon, RichText, '
      'TextSpan, Offset].length.toString()';

  /// Root library URI of the Flutter isolate, e.g. `package:acme_pay/main.dart`.
  /// The package segment is the app's pubspec name — the surest "which app".
  String? get rootLibraryUri => _vm.flutterIsolate.rootLib?.uri;

  @override
  Stream<void> get onDisconnect => _disconnectController.stream;
  final _disconnectController = StreamController<void>.broadcast();

  @override
  Future<void> attach(Uri vmServiceUri) async {
    await _vm.attach(vmServiceUri);
    for (final stream in const [
      EventStreams.kStderr,
      EventStreams.kStdout,
      EventStreams.kLogging,
    ]) {
      try {
        await _vm.service.streamListen(stream);
      } on Object {}
    }
    // Wire disconnect signal: fires once when the WebSocket closes.
    _vm.service.onDone.then((_) {
      if (!_disconnectController.isClosed) {
        _disconnectController.add(null);
      }
    }, onError: (_) {});
  }

  @override
  Future<void> disconnect() async {
    await _vm.disconnect();
    if (!_disconnectController.isClosed) {
      await _disconnectController.close();
    }
  }

  // ── connection-loss guard ─────────────────────────────────────────

  /// Wraps a VM service call and converts disconnect-class errors to
  /// [RuntimeConnectionLostError] so the tool layer can return a structured,
  /// recoverable [GlintErrorKind.connectionLost] response.
  /// Longest a single VM service call may take before it is reported as [RuntimeUnresponsiveError].
  static const callTimeout = Duration(seconds: 10);

  Future<T> _guard<T>(Future<T> Function() fn, {String op = 'vm service call'}) async {
    try {
      return await fn().timeout(callTimeout);
    } on TimeoutException {
      throw RuntimeUnresponsiveError(op, callTimeout);
    } on StateError catch (e) {
      throw RuntimeConnectionLostError(e);
    } on RPCError catch (e) {
      if (e.code == _kConnectionClosedCode) throw RuntimeConnectionLostError(e);
      rethrow;
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('closed') ||
          msg.contains('socket') ||
          msg.contains('connection refused') ||
          msg.contains('connection reset')) {
        throw RuntimeConnectionLostError(e);
      }
      rethrow;
    }
  }

  // ── inspector ─────────────────────────────────────────────────────

  @override
  Future<InspectorJson> readWidgetTree({
    required String groupName,
    bool isSummaryTree = true,
    bool withPreviews = true,
    bool fullDetails = false,
  }) async {
    final resp = await _guard(() => _vm.service.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: flutterIsolateId,
      args: InspectorParams.rootWidgetTree(
        groupName: groupName,
        isSummaryTree: isSummaryTree,
        withPreviews: withPreviews,
        fullDetails: fullDetails,
      ),
    ));
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
    final resp = await _guard(() => _vm.service.callServiceExtension(
      'ext.flutter.inspector.getDetailsSubtree',
      isolateId: flutterIsolateId,
      args: InspectorParams.detailsSubtree(
        inspectorId: inspectorId,
        groupName: groupName,
        subtreeDepth: subtreeDepth,
      ),
    ));
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
      args: InspectorParams.selectionById(
          inspectorId: inspectorId, groupName: groupName),
    );
  }

  @override
  Future<void> disposeInspectorGroup(String groupName) async {
    try {
      await _vm.service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: flutterIsolateId,
        args: InspectorParams.disposeGroup(groupName),
      );
    } on Object {
      // best-effort
    }
  }

  @override
  Future<String?> appRootDirectory() async {
    final root = rootLibraryUri;
    if (root == null) return null;
    try {
      final resolved =
          await _vm.service.lookupResolvedPackageUris(flutterIsolateId, [root]);
      final uris = resolved.uris;
      if (uris == null || uris.isEmpty) return null;
      return appRootFromMainScript(uris.first);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> setPubRootDirectories(List<String> dirs) async {
    if (dirs.isEmpty) return;
    await _guard(
      () => _vm.service.callServiceExtension(
        'ext.flutter.inspector.addPubRootDirectories',
        isolateId: flutterIsolateId,
        args: InspectorParams.pubRootDirectories(dirs),
      ),
      op: 'addPubRootDirectories',
    );
  }

  // ── evaluation ────────────────────────────────────────────────────

  /// The library glint evaluates in, found once per isolate by [scopeCanary].
  Future<String> _evalLibrary() async {
    final isolateId = flutterIsolateId;
    final cached = _evalLibId;
    if (cached != null && _evalLibIsolateId == isolateId) return cached;
    final candidates = evalLibraryCandidates(
      libraries: _vm.flutterIsolate.libraries ?? const [],
      rootLib: _vm.flutterIsolate.rootLib,
    );
    String? lastError;
    for (final id in candidates) {
      try {
        final raw = await _guard(
          () => _vm.service.evaluate(isolateId, id, scopeCanary),
          op: 'evaluate',
        );
        if (raw is InstanceRef && raw.valueAsString != null) {
          _evalLibId = id;
          _evalLibIsolateId = isolateId;
          return id;
        }
      } on RPCError catch (e) {
        lastError = e.message;
      }
    }
    throw RuntimeEvalError(
      scopeCanary,
      'no loaded library has the Flutter widgets API in scope '
      '(${candidates.length} tried)${lastError == null ? '' : ': $lastError'}',
    );
  }

  @override
  Future<InstanceRef> evaluate(String expression) async {
    final library = await _evalLibrary();
    final Object raw;
    try {
      raw = await _guard(
        () => _vm.service.evaluate(flutterIsolateId, library, expression),
        op: 'evaluate',
      );
    } on RPCError catch (e) {
      // Code 113 = expression compilation error (e.g. platform view context).
      // Wrap as RuntimeEvalError so callers get a typed, structured failure.
      throw RuntimeEvalError(expression, 'RPCError(${e.code}): ${e.message}');
    }
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
  Future<String?> evaluateWithSelection({
    required String expression,
    required String inspectorId,
    required String groupName,
  }) async {
    try {
      await setInspectorSelection(
          inspectorId: inspectorId, groupName: groupName);
      return await evaluateString(expression);
    } on Object {
      return null;
    }
  }

  @override
  Future<String?> evaluateString(String expression,
      {bool rethrowErrors = false}) async {
    final InstanceRef raw;
    try {
      raw = await evaluate(expression);
    } on RuntimeEvalError {
      if (rethrowErrors) rethrow;
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

/// Eval library ids in preference order: Flutter framework libraries, then the root library, then the rest of the app's package.
List<String> evalLibraryCandidates({
  required List<LibraryRef> libraries,
  required LibraryRef? rootLib,
}) {
  final byUri = {
    for (final l in libraries)
      if (l.uri != null && l.id != null) l.uri!: l.id!,
  };
  final ordered = <String>[
    for (final uri in VmServiceRuntime.frameworkEvalLibraries)
      if (byUri[uri] != null) byUri[uri]!,
    if (rootLib?.id != null) rootLib!.id!,
  ];
  final rootUri = rootLib?.uri;
  if (rootUri != null && rootUri.startsWith('package:')) {
    final prefix = rootUri.substring(0, rootUri.indexOf('/') + 1);
    ordered.addAll(byUri.entries
        .where((e) => e.key.startsWith(prefix))
        .map((e) => e.value)
        .take(20));
  }
  return ordered.toSet().toList();
}
