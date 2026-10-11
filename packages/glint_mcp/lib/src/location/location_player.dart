import 'dart:async';
import 'dart:math';

import 'geo.dart';
import 'location_backend.dart';

enum RouteState { playing, paused, finished, stopped, failed }

/// How a route is travelled: a steady [speed] in m/s, one fix every [interval], with optional GPS noise and lost fixes.
class RouteSpec {
  const RouteSpec({
    required this.speed,
    required this.interval,
    this.loop = false,
    this.jitterMeters = 0,
    this.dropout = 0,
  });

  final double speed;
  final Duration interval;
  final bool loop;
  final double jitterMeters;

  /// Share of fixes never sent, 0 to 1, like a phone losing GPS under a bridge.
  final double dropout;
}

/// Plays a [GeoPath] to one device in the background, so the agent keeps driving the app while the position moves.
class LocationPlayer {
  LocationPlayer(this.backend, this.path, this.spec, {Random? random}) : _rng = random ?? Random();

  final LocationBackend backend;
  final GeoPath path;
  final RouteSpec spec;
  final Random _rng;

  RouteState state = RouteState.playing;
  double meters = 0;
  int laps = 0;
  int sent = 0;
  int dropped = 0;
  int late = 0;
  Fix? lastFix;
  String? lastError;

  Timer? _timer;
  bool _sending = false;
  int _failures = 0;

  double get fraction => path.lengthMeters == 0 ? 1 : meters / path.lengthMeters;

  Duration get remaining => spec.speed <= 0
      ? Duration.zero
      : Duration(milliseconds: ((path.lengthMeters - meters) / spec.speed * 1000).round());

  int get waypoint => path.waypointAt(meters);

  bool get active => state == RouteState.playing || state == RouteState.paused;

  /// The device travels each leg itself (iOS simulator), so the host only keeps time; noise and lost fixes need per-fix sends instead.
  bool get native => backend.drivesRoutes && spec.jitterMeters == 0 && spec.dropout == 0;

  /// Sends the start position now, then moves it every interval.
  Future<void> start() async {
    if (native) {
      await _leg();
    } else {
      await _send(force: true);
    }
    if (state == RouteState.failed) return;
    _timer = Timer.periodic(spec.interval, (_) => _tick());
  }

  Future<void> pause() async {
    if (state != RouteState.playing) return;
    state = RouteState.paused;
    if (native) await _hold();
  }

  Future<void> resume() async {
    if (state != RouteState.paused) return;
    state = RouteState.playing;
    if (native) await _leg();
  }

  /// Ends the route where it is; the device keeps that position.
  Future<void> halt() async {
    if (!active) return;
    _end(RouteState.stopped);
    if (native) await _hold();
  }

  void stop() => _end(RouteState.stopped);

  /// Jumps to [toMeters] along the path and moves the device there at once.
  Future<void> seek(double toMeters) async {
    meters = toMeters.clamp(0, path.lengthMeters).toDouble();
    if (state == RouteState.finished) {
      state = RouteState.paused;
      _timer ??= Timer.periodic(spec.interval, (_) => _tick());
    }
    if (!native) return _send(force: true);
    if (state == RouteState.playing) return _leg();
    return _hold();
  }

  Fix _fixHere({bool noisy = false}) {
    final here = path.at(meters);
    final moving = state == RouteState.playing && meters < path.lengthMeters;
    return (
      at: noisy ? jitter(here.at, spec.jitterMeters, _rng) : here.at,
      speed: moving ? spec.speed : 0.0,
      heading: here.heading,
      altitude: null,
    );
  }

  Future<void> _leg() {
    final rest = path.pointsFrom(meters);
    if (rest.length < 2) return _hold();
    return _apply(_fixHere(), () => backend.drive(rest, speed: spec.speed, interval: spec.interval));
  }

  Future<void> _hold() {
    final fix = _fixHere();
    return _apply(fix, () => backend.set(fix));
  }

  void _tick() {
    if (state != RouteState.playing) return;
    meters += spec.speed * spec.interval.inMilliseconds / 1000;
    if (meters >= path.lengthMeters) {
      if (spec.loop) {
        laps++;
        meters = path.lengthMeters == 0 ? 0 : meters % path.lengthMeters;
        if (native) {
          _leg();
          return;
        }
      } else {
        meters = path.lengthMeters;
        if (native) {
          lastFix = _fixHere();
          _end(RouteState.finished);
          return;
        }
        _arrive();
        return;
      }
    }
    if (native) {
      lastFix = _fixHere();
    } else {
      _send();
    }
  }

  Future<void> _send({bool force = false}) async {
    if (_sending) {
      late++;
      return;
    }
    if (!force && spec.dropout > 0 && _rng.nextDouble() < spec.dropout) {
      dropped++;
      return;
    }
    final fix = _fixHere(noisy: true);
    await _apply(fix, () => backend.set(fix));
  }

  /// Sends the end of the route even when a fix is still in flight, so the device always stops on the last point.
  Future<void> _arrive() async {
    _timer?.cancel();
    _timer = null;
    for (var i = 0; _sending && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _sending = false;
    await _send(force: true);
    _end(RouteState.finished);
  }

  Future<void> _apply(Fix fix, Future<void> Function() send) async {
    _sending = true;
    try {
      await send().timeout(const Duration(seconds: 20), onTimeout: () => throw LocationFailed('the device did not take the fix', 'no answer in 20 s'));
      lastFix = fix;
      sent++;
      _failures = 0;
    } on LocationFailed catch (e) {
      lastError = '${e.summary}: ${e.detail}';
      if (++_failures >= 3 || native) _end(RouteState.failed);
    } finally {
      _sending = false;
    }
  }

  void _end(RouteState how) {
    if (!active) return;
    state = how;
    _timer?.cancel();
    _timer = null;
  }
}

/// What glint last told each device, and the route playing on it, for the life of this glint process.
class LocationRegistry {
  LocationRegistry._();
  static final instance = LocationRegistry._();

  final _players = <String, LocationPlayer>{};
  final _fixes = <String, Fix>{};

  LocationPlayer? player(String device) => _players[device];

  Fix? lastFix(String device) => _players[device]?.lastFix ?? _fixes[device];

  /// Stops the route on [device], if any, and returns it.
  LocationPlayer? stopRoute(String device) {
    final p = _players[device];
    if (p == null) return null;
    p.stop();
    if (p.lastFix != null) _fixes[device] = p.lastFix!;
    return p;
  }

  void play(String device, LocationPlayer p) {
    stopRoute(device);
    _players[device] = p;
  }

  /// Records a one-off position, replacing any route on [device].
  void setFix(String device, Fix fix) {
    stopRoute(device);
    _players.remove(device);
    _fixes[device] = fix;
  }

  void forget(String device) {
    stopRoute(device);
    _players.remove(device);
    _fixes.remove(device);
  }
}
