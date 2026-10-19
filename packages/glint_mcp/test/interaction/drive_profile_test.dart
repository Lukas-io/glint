import 'dart:math';

import 'package:glint_mcp/src/location/drive_profile.dart';
import 'package:glint_mcp/src/location/geo.dart';
import 'package:test/test.dart';

/// An L-shaped street pair: 600 m east, then a right-angle turn and 400 m south.
final _path = GeoPath(const [
  (lat: 6.4500, lng: 3.4700),
  (lat: 6.4500, lng: 3.4754),
  (lat: 6.4464, lng: 3.4754),
]);

/// Drives the whole path at 0.5 s steps and records (meters, speed) per step.
List<(double, double)> _drive(DriveProfile d, {double dt = 0.5}) {
  final out = <(double, double)>[];
  var m = 0.0;
  for (var i = 0; i < 2000 && m < _path.lengthMeters; i++) {
    m = min(_path.lengthMeters, m + d.step(m, dt) * dt);
    out.add((m, d.speed));
  }
  return out;
}

void main() {
  test('finds the right-angle turn', () {
    final c = cornersOf(_path);
    expect(c, hasLength(1));
    expect(c.single.degrees, closeTo(90, 1));
    expect(c.single.meters, closeTo(600, 5));
  });

  test('a curve drawn as small steps counts as one turn', () {
    final pts = [
      for (var i = 0; i <= 9; i++)
        (lat: 6.45 - 0.0002 * sin(i * pi / 18), lng: 3.47 + 0.0002 * (1 - cos(i * pi / 18)) + 0.0001 * i)
    ];
    expect(cornersOf(GeoPath([(lat: 6.45, lng: 3.468), ...pts])).length, lessThanOrEqualTo(1));
  });

  test('starts from rest, cruises inside the band, brakes for the turn, stops at the end', () {
    final d = DriveProfile(_path, minSpeed: 70 / 3.6, maxSpeed: 100 / 3.6, random: Random(1));
    final run = _drive(d);
    expect(run.first.$2, lessThanOrEqualTo(DriveProfile.accel * 0.5 + 1e-9));
    expect(run.map((r) => r.$2).reduce(max), lessThanOrEqualTo(100 / 3.6 + 1e-6));
    final atTurn = run.where((r) => (r.$1 - 600).abs() < 8).map((r) => r.$2);
    expect(atTurn.reduce(max), lessThan(7.5), reason: 'about 20 km/h through a right angle');
    expect(run.last.$1, closeTo(_path.lengthMeters, 0.01));
    expect(run.last.$2, lessThan(3));
  });

  test('speed never jumps more than the accel and brake limits allow', () {
    final run = _drive(DriveProfile(_path, minSpeed: 70 / 3.6, maxSpeed: 100 / 3.6, random: Random(7)));
    for (var i = 1; i < run.length; i++) {
      final dv = run[i].$2 - run[i - 1].$2;
      expect(dv, inInclusiveRange(-DriveProfile.brake * 0.5 - 1e-9, DriveProfile.accel * 0.5 + 1e-9));
    }
  });

  test('slowForTurns off holds cruise through the bend', () {
    final run = _drive(DriveProfile(_path, minSpeed: 60 / 3.6, maxSpeed: 60 / 3.6, slowForTurns: false));
    final atTurn = run.where((r) => (r.$1 - 600).abs() < 12).map((r) => r.$2);
    expect(atTurn.reduce(max), closeTo(60 / 3.6, 0.5));
  });

  test('time left counts the braking, so it is longer than distance over cruise', () {
    final d = DriveProfile(_path, minSpeed: 70 / 3.6, maxSpeed: 100 / 3.6, random: Random(3));
    final est = d.secondsLeft(0);
    final naive = _path.lengthMeters / (85 / 3.6);
    expect(est, greaterThan(naive * 1.2));
    final run = _drive(DriveProfile(_path, minSpeed: 85 / 3.6, maxSpeed: 85 / 3.6, random: Random(3)), dt: 0.25);
    expect(est, closeTo(run.length * 0.25, 2), reason: 'matches an actual drive at the same cruise');
  });
}
