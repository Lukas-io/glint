import 'package:flutter_test/flutter_test.dart';
import 'package:glintride/trip/geo.dart';
import 'package:glintride/trip/live.dart';

void main() {
  final route = lekkiPickupRoute;

  test('route is about 1.7 km with four turns then arrival', () {
    expect(route.length, closeTo(1736, 15));
    expect(route.maneuvers.map((m) => m.kind), [
      ManeuverKind.turnRight,
      ManeuverKind.turnLeft,
      ManeuverKind.turnRight,
      ManeuverKind.turnRight,
      ManeuverKind.arrive,
    ]);
    expect(route.maneuvers.first.text, 'Turn right onto Chief Hope Harriman Street');
  });

  test('snap finds distance along and off the route', () {
    final mid = route.pointAt(1500);
    final s = route.snap(Geo(mid.lat + 0.00005, mid.lng));
    expect(s.along, closeTo(1500, 3));
    expect(s.offRoute, closeTo(5.5, 1));
    expect(s.leg, 4);
  });

  test('live stats count down as the car moves', () {
    final near = LiveStats.of(route, route.pointAt(100), 6.7);
    final far = LiveStats.of(route, route.pointAt(route.length - 40), 6.7);
    expect(near.remaining, closeTo(route.length - 100, 1));
    expect(near.minutes, greaterThan(far.minutes));
    expect(far.arrivingNow, isTrue);
    expect(far.progress, closeTo(1 - 40 / route.length, 0.01));
  });

  test('stopped car uses city pace for the ETA', () {
    final s = LiveStats.of(route, route.start, 0);
    expect(s.etaSeconds, closeTo(route.length / LiveStats.fallbackMps, 1));
  });

  test('speed tracker derives speed from fixes and caps jumps', () {
    final t = SpeedTracker();
    final t0 = DateTime(2026, 10, 19, 8, 40);
    t.add(route.pointAt(0), t0);
    t.add(route.pointAt(10), t0.add(const Duration(seconds: 1)));
    expect(t.mps, closeTo(10, 0.5));
    t.add(route.pointAt(800), t0.add(const Duration(seconds: 2)));
    expect(t.mps, 0, reason: 'a 790 m jump in 1 s is a teleport');
  });

  test('directions: turn first, then continue, then arriving', () {
    final a = Directions.of(route, 50);
    expect(a.kind, ManeuverKind.turnRight);
    expect(a.distance, closeTo(route.maneuvers.first.at - 50, 1));
    expect(a.then?.kind, ManeuverKind.turnLeft);
    final b = Directions.of(route, route.length - 300);
    expect(b.kind, isNull);
    expect(b.text, 'Continue on Admiralty Way');
    expect(Directions.of(route, route.length - 20).kind, ManeuverKind.arrive);
  });

  test('formatting', () {
    expect(fmtDistance(637), '640 m');
    expect(fmtDistance(1934), '1.9 km');
    expect(fmtClock(DateTime(2026, 1, 1, 8, 42)), '8:42 am');
    expect(fmtClock(DateTime(2026, 1, 1, 12, 5)), '12:05 pm');
    expect(fmtTimer(const Duration(seconds: 258)), '4:18');
  });

  test('eta clock averages pace and never shows more minutes en route', () {
    final eta = EtaClock();
    final t0 = DateTime(2026, 10, 19, 15, 34);
    for (var i = 0; i < 60; i++) {
      eta.add(25, t0.add(Duration(milliseconds: 500 * i)));
    }
    expect(eta.pace, greaterThan(15));
    eta.add(5, t0.add(const Duration(seconds: 31)));
    expect(eta.pace, greaterThan(15), reason: 'one slow fix at a turn barely moves the average');
    final far = LiveStats.of(route, route.pointAt(200), 25, pace: 25);
    final slow = LiveStats.of(route, route.pointAt(300), 5, pace: 5);
    final first = eta.minutes(far);
    expect(eta.minutes(slow), lessThanOrEqualTo(first));
  });
}
