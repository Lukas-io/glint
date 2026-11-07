import 'package:vm_service/vm_service.dart';

import 'vm_service_runtime.dart';

/// Work the app has queued as the action landed that may still change the screen: one-shot timers (`Future.delayed` included) and HTTP requests in flight.
class PendingWork {
  PendingWork({this.timersDueMs = const [], this.httpInFlight = 0}) : readAt = DateTime.now();

  /// Milliseconds until each pending one-shot timer, created as the action was delivered, fires.
  final List<int> timersDueMs;

  /// HTTP requests started as the action was delivered that have no complete response and no error; seen whenever the app's HTTP timeline logging is on.
  final int httpInFlight;

  final DateTime readAt;

  /// How long a late-change wait should run to see this work land, at most [capLeft]; null when nothing is pending inside it.
  Duration? waitFor(Duration capLeft) {
    if (httpInFlight > 0) return capLeft;
    final aged = DateTime.now().difference(readAt).inMilliseconds;
    final due = timersDueMs.map((d) => d - aged).where((d) => d > 0 && d < capLeft.inMilliseconds - _landingMs);
    if (due.isEmpty) return null;
    return Duration(milliseconds: due.reduce((a, b) => a > b ? a : b) + _landingMs);
  }

  static const _landingMs = 300;

  /// A tap handler creates its timer synchronously, so only timers born from this long before the end of delivery to this long after it count.
  static const _before = Duration(milliseconds: 600);
  static const _after = Duration(milliseconds: 300);

  /// Each one-shot timer as `msSinceCreated:msUntilDue`, creation being `_wakeupTime - _milliSeconds - 1`; the same text every time.
  static const _timersExpression = '((int now) => _Timer._heap._list.take(_Timer._heap._used)'
      '.where((t) => !t._repeating && t._callback != null)'
      '.map((t) => (now - (t._wakeupTime - t._milliSeconds - 1)).toString() + ":" + (t._wakeupTime - now).toString())'
      '.join(","))(VMLibraryHooks.timerMillisecondClock())';

  /// Reads the app's pending timers (the VM keeps them in a private heap of the `dart:isolate` library) and in-flight requests; [sinceDelivery] is how long ago delivery ended. Empty when the VM or SDK does not expose them.
  static Future<PendingWork> read(VmServiceRuntime runtime, Duration sinceDelivery, {int? appClockOffsetMs}) async {
    final results = await Future.wait([
      _timers(runtime, sinceDelivery),
      _httpInFlight(runtime, sinceDelivery, appClockOffsetMs),
    ]);
    return PendingWork(timersDueMs: results[0] as List<int>, httpInFlight: results[1] as int);
  }

  static Future<List<int>> _timers(VmServiceRuntime runtime, Duration sinceDelivery) async {
    try {
      final text = await runtime.evaluateStringIn(_timersExpression, librarySuffix: 'dart:isolate');
      final oldest = sinceDelivery + _before;
      final newest = sinceDelivery - _after;
      final due = <int>[];
      for (final pair in (text ?? '').split(',')) {
        final parts = pair.split(':');
        final age = int.tryParse(parts.first);
        final left = parts.length == 2 ? int.tryParse(parts.last) : null;
        if (age == null || left == null) continue;
        if (age <= oldest.inMilliseconds && age >= newest.inMilliseconds) due.add(left);
      }
      return due;
    } on Object {
      return const [];
    }
  }

  static Future<int> _httpInFlight(VmServiceRuntime runtime, Duration sinceDelivery, int? offsetMs) async {
    if (offsetMs == null) return 0;
    try {
      final appNow = DateTime.now().add(Duration(milliseconds: offsetMs));
      final from = appNow.subtract(sinceDelivery + _before);
      final profile = await runtime.rawService
          .getHttpProfile(runtime.flutterIsolateId, updatedSince: from)
          .timeout(const Duration(seconds: 2));
      return profile.requests
          .where((r) => !r.startTime.isBefore(from) && r.request?.error == null && !(r.response?.isComplete ?? false))
          .where((r) => r.response?.error == null)
          .length;
    } on Object {
      return 0;
    }
  }
}
