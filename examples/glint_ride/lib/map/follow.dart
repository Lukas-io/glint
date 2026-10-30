import 'dart:math' as math;

import 'dart:io';

import 'package:flutter/scheduler.dart';

import '../trip/geo.dart';

/// Moves the car along the road continuously: a target slides ahead at the car's speed, and a spring as damped as Sprung(28) chases it.
class CarFollower {
  CarFollower(TickerProvider vsync, this.route, {required this.onTick}) : _along = 0, _target = 0 {
    _ticker = vsync.createTicker(_step);
  }

  final TripRoute route;
  final void Function() onTick;
  late final Ticker _ticker;

  /// Spring stiffness and damping; damping ratio 1.4 matches Sprung(28) (Sprung(20) is critical).
  static const _k = 70.0;
  static final _c = 2 * math.sqrt(_k) * 1.4;

  double _along, _v = 0, _target;
  double _fixAlong = 0, _mps = 0;

  /// Wall clock for dead reckoning; ticker time restarts at zero whenever the ticker does.
  final _clock = Stopwatch()..start();
  Duration? _fixAt, _last, _drawn;
  Geo? _offRoute;

  /// Meters along the route the car is drawn at.
  double get along => _along;

  /// Marker moves cross a platform channel: every frame on iOS, 25 a second on Android so the emulator keeps up.
  static final _frame = Duration(milliseconds: Platform.isIOS ? 15 : 40);

  Geo get position => _offRoute ?? route.pointAt(_along);

  /// Bearing across the next and last few meters, so the car turns through corners instead of snapping.
  double get heading => route.pointAt(_along - 7).bearingTo(route.pointAt(_along + 7));

  /// Takes a GPS fix; fixes far from the road are drawn where they are.
  void fix(Geo g, double mps) {
    final s = route.snap(g);
    if (s.offRoute > 40) {
      _offRoute = g;
      onTick();
      return;
    }
    _offRoute = null;
    // First fix, or a teleport: jump there instead of racing across the map.
    if (_fixAt == null || (s.along - _along).abs() > 150) {
      _along = s.along;
      _v = 0;
    }
    _fixAlong = s.along;
    _mps = mps;
    _fixAt = _clock.elapsed;
    if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _step(Duration _) {
    final now = _clock.elapsed;
    // Real elapsed time, so slow frames can't make the car fall behind.
    final dt = _last == null ? 1 / 60 : math.min(2.0, (now - _last!).inMicroseconds / 1e6);
    _last = now;
    // Dead-reckon for up to 3 s past the last fix so the car keeps rolling through a late update.
    final since = math.min(3.0, (now - (_fixAt ?? now)).inMicroseconds / 1e6);
    _target = math.min(route.length, _fixAlong + _mps * since);
    for (var t = dt; t > 0; t -= 1 / 120) {
      final h = math.min(t, 1 / 120);
      _v += (_k * (_target - _along) - _c * _v) * h;
      _along += _v * h;
    }
    final settled = (_target - _along).abs() < 0.05 && _v.abs() < 0.05 && _mps < 0.3;
    if (settled || _drawn == null || now - _drawn! >= _frame) {
      _drawn = now;
      onTick();
    }
    if (settled) {
      _along = _target;
      _ticker.stop();
    }
  }

  void dispose() => _ticker.dispose();
}
