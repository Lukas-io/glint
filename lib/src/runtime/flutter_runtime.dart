/// Transport abstraction over the running Flutter app's VM service.
///
/// **Every glint primitive that talks to the live app goes through this
/// interface.** No other code reaches `vm.service.callServiceExtension`
/// or `vm.service.evaluate` directly. When Flutter's VM service shape
/// drifts (it has — `getRootWidgetTree`'s `fullDetails` flag, the
/// `valueAsStringIsTruncated` refetch, the `ext.flutter.inspector.*`
/// argument map — and it will keep drifting), there is ONE adapter to
/// patch instead of a scattered hunt across modules.
library;

import 'package:vm_service/vm_service.dart';

/// Inspector object-group identity used by glint. Read groups are
/// disposed when the scene is freed; resolve groups outlive the read
/// that produced them.
enum InspectorGroupKind { read, resolve }

/// One opaque inspector subtree (the JSON returned by Flutter's
/// `getRootWidgetTree` / `getDetailsSubtree`). Glint's perception
/// layer parses this into [SceneNode]s; the runtime stops at the JSON.
typedef InspectorJson = Map<String, Object?>;

abstract class FlutterRuntime {
  /// Fires once when the VM service WebSocket closes (hot restart, app kill,
  /// etc.). Use this to trigger auto-reconnect. Implementors broadcast one
  /// event then close the stream.
  Stream<void> get onDisconnect;

  /// Currently attached to a VM service.
  bool get isAttached;

  /// The URI we're attached to, when known.
  Uri? get attachedUri;

  /// Attach to a VM service over its WebSocket URI. Selects the first
  /// isolate exposing `ext.flutter.*` extensions and listens to the
  /// stderr / stdout / logging event streams. Subsequent calls re-attach.
  Future<void> attach(Uri vmServiceUri);

  /// Best-effort disconnect; safe to call multiple times.
  Future<void> disconnect();

  // ── inspector ─────────────────────────────────────────────────────

  /// Returns the inspector's widget tree as raw DiagnosticsNode JSON.
  /// `isSummaryTree: true` (the default) filters out framework
  /// internals; `false` returns the full element tree.
  Future<InspectorJson> readWidgetTree({
    required String groupName,
    bool isSummaryTree = true,
    bool withPreviews = true,
    bool fullDetails = false,
  });

  /// Returns the subtree rooted at [inspectorId] including each node's
  /// DiagnosticsProperty values. Used for selective per-node detail
  /// reads (input field values, icon codepoints, etc.).
  Future<InspectorJson> readDetailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  });

  /// Sets `WidgetInspectorService.instance.selection` to [inspectorId]
  /// so a subsequent [evaluate] has `selection.currentElement` available.
  Future<void> setInspectorSelection({
    required String inspectorId,
    required String groupName,
  });

  /// Best-effort cleanup of the inspector's object-group id table.
  /// Never throws — callers don't need to wrap this.
  Future<void> disposeInspectorGroup(String groupName);

  // ── evaluation ────────────────────────────────────────────────────

  /// Evaluates [expression] against the Flutter isolate's root library.
  /// Returns the raw [InstanceRef] for the caller to crack open by type.
  /// Throws [RuntimeEvalError] on compilation error or ErrorRef return.
  Future<InstanceRef> evaluate(String expression);

  /// Evaluates [expression] and returns its `valueAsString`, transparently
  /// refetching via `getObject` when the value is truncated past the
  /// 128-char preview. Returns null when the expression returned a
  /// non-string (different type, ErrorRef converted to null, etc.).
  Future<String?> evaluateString(String expression);

  // ── streams ───────────────────────────────────────────────────────

  /// Broadcast stream of `WriteEvent`s from the Flutter app's stderr.
  Stream<Event> get stderrEvents;

  /// Broadcast stream of `WriteEvent`s from the Flutter app's stdout.
  /// FlutterError dumps land here (not stderr — debugPrint → print →
  /// stdout), so error-capture pipelines must subscribe.
  Stream<Event> get stdoutEvents;

  /// Broadcast stream of `LoggingEvent`s from `developer.log` and
  /// `package:logging` consumers.
  Stream<Event> get loggingEvents;

  // ── escape hatch ──────────────────────────────────────────────────

  /// Raw VM service handle. Try not to use this from glint code — the
  /// whole point of [FlutterRuntime] is to keep this surface contained
  /// to one adapter. Exposed for verify scripts and adapter authors.
  VmService get rawService;

  /// Raw selected Flutter isolate id. Same caveat as [rawService].
  String get flutterIsolateId;
}

/// Thrown when [FlutterRuntime.evaluate] either fails to compile or
/// returns an ErrorRef. Carries the original error detail.
class RuntimeEvalError implements Exception {
  RuntimeEvalError(this.expression, this.message);
  final String expression;
  final String message;
  @override
  String toString() => 'RuntimeEvalError($expression): $message';
}

/// Thrown when the VM service WebSocket connection drops — typically because
/// the app performed a hot restart or was terminated. Tools catch this and
/// return [GlintErrorKind.connectionLost] so the agent knows to re-attach.
class RuntimeConnectionLostError implements Exception {
  RuntimeConnectionLostError(this.cause);
  final Object cause;
  @override
  String toString() => 'RuntimeConnectionLostError: $cause';
}
