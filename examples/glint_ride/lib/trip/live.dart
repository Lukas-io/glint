import 'dart:math' as math;

import 'geo.dart';

/// Trip phase shared by both apps.
enum Phase { enroute, arrived, onTrip }

/// Speed from GPS fixes: the fix's own speed when it has one, else distance over the last 2 s, so uneven fix timing can't spike it.
class SpeedTracker {
  final _recent = <(Geo, DateTime)>[];
  double _mps = 0;

  /// Meters per second.
  double get mps => _mps;

  void add(Geo p, DateTime at, {double? reported}) {
    final last = _recent.isEmpty ? null : _recent.last;
    if (last != null) {
      final dt = at.difference(last.$2).inMilliseconds / 1000;
      // Faster than 40 m/s is a teleport (the GPS was moved), not driving: start over.
      if (dt > 0 && last.$1.distanceTo(p) / dt > 40) {
        _recent.clear();
        _mps = 0;
      }
    }
    _recent.add((p, at));
    _recent.removeWhere((f) => at.difference(f.$2).inMilliseconds > 2000);
    if (reported != null && reported > 0.3) {
      _mps = reported;
      return;
    }
    if (_recent.length < 2) return;
    final span = _recent.last.$2.difference(_recent.first.$2).inMilliseconds / 1000;
    if (span < 0.9) return;
    var meters = 0.0;
    for (var i = 1; i < _recent.length; i++) {
      meters += _recent[i - 1].$1.distanceTo(_recent[i].$1);
    }
    _mps = meters / span;
  }
}

/// Keeps the ETA calm: pace is speed averaged over about 20 s of driving, and the shown minutes never climb back up.
class EtaClock {
  double _pace = LiveStats.fallbackMps;
  DateTime? _at;
  int? _shown;
  double _lastRemaining = double.infinity;

  /// Average driving pace in m/s; stops at lights don't drag it down.
  double get pace => _pace;

  void add(double mps, DateTime at) {
    final last = _at;
    _at = at;
    if (last == null || mps < 1.5) return;
    final dt = at.difference(last).inMilliseconds / 1000;
    _pace += (mps - _pace) * (1 - math.exp(-dt / 20));
  }

  /// Minutes to show for [s]: never more than last time, unless the car jumped back or [reset] was called.
  int minutes(LiveStats s) {
    if (s.remaining > _lastRemaining + 150) {
      _shown = null;
      _arrival = null;
    }
    _lastRemaining = s.remaining;
    final m = s.minutes;
    return _shown = _shown == null ? m : math.min(_shown!, m);
  }

  DateTime? _arrival;

  /// Arrival time for [s]: while the car moves it only gets earlier; while it waits it follows the clock.
  DateTime arrival(LiveStats s, DateTime now) {
    final fresh = s.arrivalFrom(now);
    final kept = s.speedKmh < 5 ? null : _arrival;
    final a = kept == null || fresh.isBefore(kept) ? fresh : (kept.isBefore(now) ? now : kept);
    return _arrival = a;
  }

  void reset() {
    _shown = null;
    _arrival = null;
    _lastRemaining = double.infinity;
  }
}

/// Everything the live bar shows, worked out from the driver's position.
class LiveStats {
  const LiveStats({
    required this.remaining,
    required this.progress,
    required this.etaSeconds,
    required this.speedKmh,
    required this.snap,
  });

  /// Meters left along the route.
  final double remaining;

  /// Share of the route done, 0 to 1.
  final double progress;
  final double etaSeconds;
  final double speedKmh;
  final Snap snap;

  /// City pace used when the car is stopped or speed is unknown.
  static const fallbackMps = 6.7;

  /// [pace] is the average to time the rest of the trip by; without it the current speed is used.
  static LiveStats of(TripRoute route, Geo car, double mps, {double? pace}) {
    final s = route.snap(car);
    final remaining = math.max(0.0, route.length - s.along);
    pace = math.max(pace ?? (mps < 1.5 ? fallbackMps : mps), 3.0);
    return LiveStats(
      remaining: remaining,
      progress: (s.along / route.length).clamp(0.0, 1.0),
      etaSeconds: remaining / pace,
      speedKmh: mps * 3.6,
      snap: s,
    );
  }

  int get minutes => math.max(1, (etaSeconds / 60).ceil());
  bool get arrivingNow => remaining < 100;

  DateTime arrivalFrom(DateTime now) => now.add(Duration(seconds: etaSeconds.round()));
}

/// "640 m" under a kilometer, "1.2 km" above.
String fmtDistance(double m) {
  if (m < 1000) return '${(m / 10).round() * 10} m';
  return '${(m / 1000).toStringAsFixed(1)} km';
}

/// "8:42 am".
String fmtClock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
}

/// "4:18".
String fmtTimer(Duration d) {
  final s = d.inSeconds.abs();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The driver's next instruction, as the directions banner shows it.
class Directions {
  const Directions({required this.kind, required this.distance, required this.text, this.then});

  /// Null while driving straight toward the next maneuver.
  final ManeuverKind? kind;

  /// Meters to the next maneuver; null once arriving.
  final double? distance;
  final String text;
  final Maneuver? then;

  static Directions of(TripRoute route, double along) {
    final next = route.maneuvers.firstWhere((m) => m.at > along + 8, orElse: () => route.maneuvers.last);
    final dist = math.max(0.0, next.at - along);
    if (next.kind == ManeuverKind.arrive) {
      if (dist < 50) return Directions(kind: ManeuverKind.arrive, distance: null, text: next.text);
      return Directions(
        kind: null,
        distance: dist,
        text: 'Continue on ${route.legs[route.legAt(along)].road}',
        then: next,
      );
    }
    final i = route.maneuvers.indexOf(next);
    return Directions(kind: next.kind, distance: dist, text: next.text, then: route.maneuvers[i + 1]);
  }
}

/// Free waiting at the pickup before charges start.
const freeWaiting = Duration(minutes: 5);
