import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'glint_config.dart';

/// Anonymous usage telemetry. Opt-in via [GlintConfig.telemetryEnabled].
/// Events have no PII: no VM URIs, no glintIds, no app names, no source
/// paths. Only kinds + counts + durations + platform + errorKind.
///
/// Schema (one event per call):
/// ```
/// {
///   "v": 1,
///   "instance": "<uuid v4 generated once per process>",
///   "event": "tool_call" | "session" | "attach" | "error",
///   "ts": "<iso8601>",
///   "platform": "ios" | "android" | null,
///   "fields": { ...event-specific... }
/// }
/// ```
///
/// Transport: HTTP POST to [GlintConfig.telemetryEndpoint]. 2s timeout,
/// fire-and-forget — a failed POST never breaks a tool call.
class TelemetryClient {
  TelemetryClient(this.config) : _instance = _randomInstance();

  final GlintConfig config;
  final String _instance;
  String? _platform;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 5);

  /// Called from AttachTool — captures the platform once so subsequent
  /// events can include it without re-reading.
  void noteAttach(String platform) {
    _platform = platform;
    fire('attach', {'platform': platform});
  }

  void noteToolCall({
    required String name,
    required int elapsedMs,
    String? errorKind,
    bool? armed,
  }) {
    fire('tool_call', {
      'name': name,
      'elapsedMs': elapsedMs,
      if (errorKind != null) 'errorKind': errorKind,
      if (armed != null) 'armed': armed,
    });
  }

  void noteSession(String op) => fire('session', {'op': op});

  /// Send one event. Returns immediately — the POST is detached.
  void fire(String event, Map<String, Object?> fields) {
    if (!config.telemetryEnabled) return;
    final body = {
      'v': 1,
      'instance': _instance,
      'event': event,
      'ts': DateTime.now().toUtc().toIso8601String(),
      if (_platform != null) 'platform': _platform,
      'fields': fields,
    };
    // Detached: don't await, swallow any error.
    unawaited(_post(body));
  }

  Future<void> _post(Map<String, Object?> body) async {
    try {
      final uri = Uri.parse(config.telemetryEndpoint);
      final req = await _http.postUrl(uri);
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      // Drain the response so the socket can be reused.
      await resp.drain<void>();
    } on Object {
      // never bubble
    }
  }

  Future<void> close() async {
    _http.close(force: true);
  }

  static final _rng = Random.secure();

  /// Cryptographically-secure UUIDv4. Fresh per process — no persistence,
  /// no cross-run linkage.
  static String _randomInstance() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
