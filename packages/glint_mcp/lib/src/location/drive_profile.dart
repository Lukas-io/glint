import 'dart:math';

import 'geo.dart';

/// Speed that changes like a driver's: cruise wanders between [minSpeed] and [maxSpeed], braking before turns and the stop.
class DriveProfile {
  DriveProfile(GeoPath path, {required this.minSpeed, required this.maxSpeed, this.slowForTurns = true, Random? random})
      : _rng = random ?? Random(),
        _length = path.lengthMeters,
        _corners = slowForTurns ? cornersOf(path) : const [] {
    _cruise = _pickCruise();
  }

  /// Cruise bounds in m/s.
  final double minSpeed, maxSpeed;
  final bool slowForTurns;
  final Random _rng;
  final double _length;
  final List<Corner> _corners;

  /// Firm but ordinary town driving, in m/s².
  static const accel = 2.4, brake = 3.2;

  /// Braking is planned gentler than [brake], so stepped updates still slow in time.
  static const _plan = brake * 0.7;

  /// Speed through a right-angle turn, in m/s (about 20 km/h).
  static const turnSpeed = 5.5;

  double speed = 0;
  late double _cruise;
  double _untilChange = 0;

  /// Upcoming turns this profile slows for.
  int get turns => _corners.length;

  double _pickCruise() {
    _untilChange = 3 + _rng.nextDouble() * 4;
    return minSpeed + _rng.nextDouble() * (maxSpeed - minSpeed);
  }

  /// Fastest speed through a corner turning [degrees]: full cruise below 20°, [turnSpeed] at 90° and sharper.
  static double cornerSpeed(double degrees, double cruise) {
    final t = ((degrees - 20) / 70).clamp(0.0, 1.0);
    return cruise + (min(cruise, turnSpeed) - cruise) * t;
  }

  /// Seconds to the end from [from] metres at the current speed, driven at the average cruise; slowing for turns and the stop included.
  double secondsLeft(double from) {
    final ghost = DriveProfile._ghost(this);
    var m = from, t = 0.0;
    const dt = 0.25;
    while (m < _length && t < 24 * 3600) {
      m += ghost.step(m, dt) * dt;
      t += dt;
    }
    return t;
  }

  /// A copy that holds the average cruise, so estimates don't consume or depend on the random wander.
  DriveProfile._ghost(DriveProfile o)
      : minSpeed = (o.minSpeed + o.maxSpeed) / 2,
        maxSpeed = (o.minSpeed + o.maxSpeed) / 2,
        slowForTurns = o.slowForTurns,
        _rng = Random(0),
        _length = o._length,
        _corners = o._corners {
    _cruise = minSpeed;
    _untilChange = double.infinity;
    speed = o.speed;
  }

  /// Moves time on by [dt] seconds at [meters] along the path and returns the new speed.
  double step(double meters, double dt) {
    _untilChange -= dt;
    if (_untilChange <= 0) _cruise = _pickCruise();
    var target = _cruise;
    for (final c in _corners) {
      final ahead = c.meters - meters;
      if (ahead < -10 || ahead > 300) continue;
      // Reach the corner's speed 10 m before it and hold it until 10 m past.
      final v = sqrt(pow(cornerSpeed(c.degrees, _cruise), 2) + 2 * _plan * max(0.0, ahead - 10));
      target = min(target, v);
    }
    final left = _length - meters;
    target = min(target, sqrt(2 * _plan * max(0.0, left - 1)));
    // Never halt short of the end: creep the last metres in.
    if (left > 0) target = max(target, left > 2 ? 1.5 : 1.0);
    final change = (target - speed).clamp(-brake * dt, accel * dt);
    speed = max(0.0, speed + change);
    return speed;
  }
}

/// A bend in a path: where it is and how far the heading turns there.
typedef Corner = ({double meters, double degrees});

/// Bends that slow a driver: waypoints within 25 m of each other merge, so a curve drawn as many small steps counts as one turn.
List<Corner> cornersOf(GeoPath path) {
  final p = path.points;
  final out = <Corner>[];
  var start = -1.0, last = -1.0, sum = 0.0;
  void flush() {
    if (start >= 0 && sum.abs() > 15) out.add((meters: (start + last) / 2, degrees: sum.abs()));
    start = -1;
    sum = 0;
  }

  for (var i = 1; i < p.length - 1; i++) {
    final a = bearingDegrees(p[i - 1], p[i]), b = bearingDegrees(p[i], p[i + 1]);
    final turn = (b - a + 540) % 360 - 180;
    if (turn.abs() < 3) continue;
    final at = path.metersAtWaypoint(i);
    if (start >= 0 && at - last > 25) flush();
    if (start < 0) start = at;
    last = at;
    sum += turn;
  }
  flush();
  return out;
}
