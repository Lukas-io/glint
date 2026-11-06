import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'app_alert.dart';

/// Reads one app's dart:io HTTP profile on a timer and raises an [AppAlert] for each request that failed (4xx, 5xx or a transport error); runs only while something holds it.
class HttpFailureMonitor {
  HttpFailureMonitor({
    required VmService? Function() service,
    required bool Function() live,
    required void Function(AppAlert) onAlert,
  })  : _service = service,
        _live = live,
        _onAlert = onAlert;

  static const pollEvery = Duration(seconds: 2);
  static const _callLimit = Duration(seconds: 5);
  static const _prepareLimit = Duration(seconds: 10);
  static const _maxPerPoll = 10;
  static const _maxSeen = 2000;
  static const _responseGrace = Duration(seconds: 30);
  static const _rediscoverAfter = Duration(seconds: 15);
  static const _profileRpc = 'ext.dart.io.getHttpProfile';

  final VmService? Function() _service;
  final bool Function() _live;
  final void Function(AppAlert) _onAlert;
  final Map<String, DateTime?> _cursors = {};
  final Set<String> _seen = {};
  final Set<String> _baselined = {};
  VmService? _discoveredOn;
  DateTime? _discoveredAt;
  Timer? _timer;
  bool _preparing = false;
  bool _polling = false;
  int _holds = 0;

  /// Why requests cannot be read right now, null while they can.
  String? unavailable;

  bool get running => _timer != null;

  /// Starts polling for one more holder and returns why it cannot read requests, null when it can.
  Future<String?> acquire() async {
    _holds++;
    if (_holds > 1) return unavailable;
    _cursors.clear();
    _baselined.clear();
    _preparing = true;
    _timer = Timer.periodic(pollEvery, (_) => _poll());
    final note = await _prepare().timeout(_prepareLimit,
        onTimeout: () => 'the app did not answer within ${_prepareLimit.inSeconds} s; polling keeps trying');
    unavailable = note;
    _preparing = false;
    return note;
  }

  void release() {
    if (_holds == 0) return;
    _holds--;
    if (_holds > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _holds = 0;
    _timer?.cancel();
    _timer = null;
  }

  Future<String?> _prepare() async {
    final service = _service();
    if (service == null || !_live()) return 'the connection to the app is down';
    try {
      final isolates = await _discover(service);
      if (isolates.isEmpty) return 'no isolate of the app exposes dart:io HTTP profiling';
      for (final id in isolates) {
        await _enableLogging(service, id);
        await _baseline(service, id);
      }
      return null;
    } on Object catch (e) {
      return 'could not read the HTTP profile: ${'$e'.split('\n').first}';
    }
  }

  Future<List<String>> _discover(VmService service) async {
    final vm = await service.getVM().timeout(_callLimit);
    final found = <String>[];
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      try {
        final isolate = await service.getIsolate(id).timeout(_callLimit);
        if ((isolate.extensionRPCs ?? const <String>[]).contains(_profileRpc)) found.add(id);
      } on SentinelException {
        continue;
      }
    }
    _discoveredOn = service;
    _discoveredAt = DateTime.now();
    _cursors.removeWhere((id, _) => !found.contains(id));
    return found;
  }

  Future<void> _enableLogging(VmService service, String isolateId) async {
    try {
      final state = await service.httpEnableTimelineLogging(isolateId).timeout(_callLimit);
      if (!state.enabled) await service.httpEnableTimelineLogging(isolateId, true).timeout(_callLimit);
    } on Object {
      return;
    }
  }

  Future<void> _baseline(VmService service, String isolateId) async {
    final profile = await service.getHttpProfile(isolateId).timeout(_callLimit);
    _cursors[isolateId] = profile.timestamp;
    for (final r in profile.requests) {
      _seen.add(r.id);
    }
    _trimSeen();
    _baselined.add(isolateId);
  }

  Future<void> _poll() async {
    if (_polling || _preparing || _holds == 0 || !_live()) return;
    final service = _service();
    if (service == null) return;
    _polling = true;
    try {
      var isolates = _cursors.keys.toList();
      final stale = _discoveredAt == null || DateTime.now().difference(_discoveredAt!) > _rediscoverAfter;
      if (isolates.isEmpty || !identical(_discoveredOn, service) || stale) {
        if (!identical(_discoveredOn, service)) _baselined.clear();
        isolates = await _discover(service);
      }
      var emitted = 0;
      var suppressed = 0;
      for (final id in isolates) {
        try {
          if (!_baselined.contains(id)) {
            await _baseline(service, id);
            continue;
          }
          final profile = await service.getHttpProfile(id, updatedSince: _cursors[id]).timeout(_callLimit);
          _cursors[id] = profile.timestamp;
          for (final r in profile.requests) {
            final alert = _judge(r);
            if (alert == null) continue;
            if (emitted >= _maxPerPoll) {
              suppressed++;
              continue;
            }
            emitted++;
            _onAlert(alert);
          }
        } on SentinelException {
          _discoveredAt = null;
        } on RPCError {
          _discoveredAt = null;
          _baselined.remove(id);
        } on TimeoutException {
          _discoveredAt = null;
        }
      }
      if (suppressed > 0) {
        _onAlert(AppAlert(AlertKind.http, 'http', '$suppressed more failed requests', {
          'suppressed': suppressed,
          'note': 'more than $_maxPerPoll failures in ${pollEvery.inSeconds} s; the rest are not listed',
        }));
      }
      unavailable = null;
    } on Object catch (e) {
      unavailable = 'could not read the HTTP profile: ${'$e'.split('\n').first}';
    } finally {
      _polling = false;
    }
  }

  AppAlert? _judge(HttpProfileRequest r) {
    if (_seen.contains(r.id)) return null;
    final error = r.request?.error ?? r.response?.error;
    final status = r.response?.statusCode;
    final failedStatus = status != null && status >= 400;
    if (error == null && !failedStatus) return null;
    final responded = r.response?.isComplete ?? false;
    final waited = DateTime.now().difference(r.startTime) > _responseGrace;
    if (error == null && !responded && !waited) return null;
    _seen.add(r.id);
    _trimSeen();
    final end = r.response?.endTime ?? r.endTime;
    final duration = end?.difference(r.startTime).inMilliseconds;
    final url = describeUrl(r.uri);
    final what = error != null ? 'failed: ${_clip(error, 120)}' : '$status';
    return AppAlert(AlertKind.http, 'http', '${r.method} $url $what', {
      'method': r.method,
      'url': url,
      if (status != null) 'status': status,
      if (duration != null) 'durationMs': duration,
      if (error != null) 'error': _clip(error, 200),
    });
  }

  void _trimSeen() {
    while (_seen.length > _maxSeen) {
      _seen.remove(_seen.first);
    }
  }

  static String _clip(String s, int n) => s.length > n ? '${s.substring(0, n - 1)}…' : s;

  /// `https://host/path?key=*&other=*`: the query's values are replaced, its keys kept; user info and fragment dropped.
  static String describeUrl(Uri uri) {
    final port = uri.hasPort ? ':${uri.port}' : '';
    final keys = uri.hasQuery ? [for (final p in uri.query.split('&')) p.split('=').first] : const <String>[];
    final query = keys.where((k) => k.isNotEmpty).map((k) => '$k=*').join('&');
    return '${uri.scheme}://${uri.host}$port${uri.path}${query.isEmpty ? '' : '?$query'}';
  }
}
