import 'dart:math' as math;

/// A latitude/longitude pair in degrees, independent of any map plugin.
class Geo {
  const Geo(this.lat, this.lng);

  final double lat;
  final double lng;

  /// Great-circle distance in meters.
  double distanceTo(Geo o) {
    const r = 6371000.0;
    final p1 = _rad(lat), p2 = _rad(o.lat);
    final dp = p2 - p1, dl = _rad(o.lng - lng);
    final h = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
    return 2 * r * math.asin(math.sqrt(h.toDouble()));
  }

  /// Initial compass bearing toward [o], 0 = north, clockwise.
  double bearingTo(Geo o) {
    final p1 = _rad(lat), p2 = _rad(o.lat), dl = _rad(o.lng - lng);
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (_deg(math.atan2(y, x)) + 360) % 360;
  }

  /// The point [meters] away along compass [bearing].
  Geo offset(double bearing, double meters) {
    const r = 6371000.0;
    final d = meters / r, b = _rad(bearing), p1 = _rad(lat), l1 = _rad(lng);
    final p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b));
    final l2 = l1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2));
    return Geo(_deg(p2), _deg(l2));
  }

  Geo lerp(Geo o, double t) => Geo(lat + (o.lat - lat) * t, lng + (o.lng - lng) * t);

  @override
  String toString() => '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
}

double _rad(double d) => d * math.pi / 180;
double _deg(double r) => r * 180 / math.pi;

/// One named road of a route.
class Leg {
  const Leg(this.road, this.points);

  final String road;
  final List<Geo> points;
}

/// What the driver must do next and where along the route it happens.
enum ManeuverKind { turnRight, turnLeft, arrive }

class Maneuver {
  const Maneuver(this.kind, this.at, this.text);

  final ManeuverKind kind;

  /// Meters from the route start.
  final double at;
  final String text;
}

/// Where a position sits on a route.
class Snap {
  const Snap(this.along, this.offRoute, this.leg, this.point);

  /// Meters from the route start to the nearest route point.
  final double along;

  /// Meters between the position and the route.
  final double offRoute;
  final int leg;
  final Geo point;
}

/// A fixed polyline made of named legs, with distances and maneuvers precomputed.
class TripRoute {
  TripRoute(this.legs, {required String arriveText}) {
    for (var l = 0; l < legs.length; l++) {
      for (final p in legs[l].points) {
        if (_points.isNotEmpty && _points.last.lat == p.lat && _points.last.lng == p.lng) continue;
        _cum.add(_points.isEmpty ? 0 : _cum.last + _points.last.distanceTo(p));
        _points.add(p);
        _legOf.add(l);
      }
      _legEnd.add(_cum.last);
    }
    for (var l = 1; l < legs.length; l++) {
      final a = _bearingInto(l), b = legs[l].points[0].bearingTo(legs[l].points[1]);
      final turn = ((b - a + 540) % 360) - 180;
      maneuvers.add(
        Maneuver(
          turn >= 0 ? ManeuverKind.turnRight : ManeuverKind.turnLeft,
          _legEnd[l - 1],
          'Turn ${turn >= 0 ? 'right' : 'left'} onto ${legs[l].road}',
        ),
      );
    }
    maneuvers.add(Maneuver(ManeuverKind.arrive, length, arriveText));
  }

  final List<Leg> legs;
  final maneuvers = <Maneuver>[];
  final _points = <Geo>[];
  final _cum = <double>[];
  final _legOf = <int>[];
  final _legEnd = <double>[];

  List<Geo> get points => List.unmodifiable(_points);
  double get length => _cum.last;
  Geo get start => _points.first;
  Geo get end => _points.last;

  double _bearingInto(int leg) {
    final prev = legs[leg - 1].points;
    return prev[prev.length - 2].bearingTo(prev.last);
  }

  /// Leg index for a distance along the route.
  int legAt(double along) {
    for (var l = 0; l < _legEnd.length; l++) {
      if (along < _legEnd[l]) return l;
    }
    return legs.length - 1;
  }

  /// The route point [along] meters from the start.
  Geo pointAt(double along) {
    final d = along.clamp(0, length).toDouble();
    for (var i = 1; i < _points.length; i++) {
      if (d <= _cum[i]) {
        final seg = _cum[i] - _cum[i - 1];
        return _points[i - 1].lerp(_points[i], seg == 0 ? 0 : (d - _cum[i - 1]) / seg);
      }
    }
    return end;
  }

  /// Heading of the route at [along] meters.
  double headingAt(double along) {
    final d = along.clamp(0, length).toDouble();
    for (var i = 1; i < _points.length; i++) {
      if (d <= _cum[i]) return _points[i - 1].bearingTo(_points[i]);
    }
    return _points[_points.length - 2].bearingTo(end);
  }

  /// The car, then every route corner still ahead of it, then the end.
  List<Geo> ahead(double along, Geo car) => [
    car,
    for (var i = 0; i < _points.length; i++)
      if (_cum[i] > along) _points[i],
  ];

  /// The route from [along] meters to the end.
  List<Geo> pointsFrom(double along) => [
    pointAt(along),
    for (var i = 0; i < _points.length; i++)
      if (_cum[i] > along) _points[i],
  ];

  /// Nearest point on the route to [p], using a local flat projection.
  Snap snap(Geo p) {
    final k = math.cos(_rad(p.lat));
    const m = 111320.0;
    Snap? best;
    for (var i = 1; i < _points.length; i++) {
      final a = _points[i - 1], b = _points[i];
      final ax = (a.lng - p.lng) * m * k, ay = (a.lat - p.lat) * m;
      final bx = (b.lng - p.lng) * m * k, by = (b.lat - p.lat) * m;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
      final cx = ax + t * dx, cy = ay + t * dy;
      final off = math.sqrt(cx * cx + cy * cy);
      if (best == null || off < best.offRoute) {
        final along = _cum[i - 1] + t * (_cum[i] - _cum[i - 1]);
        best = Snap(along, off, _legOf[i], a.lerp(b, t));
      }
    }
    return best!;
  }
}

/// The demo trip in Lekki Phase 1: four turns through the side streets to the pickup by Lekki British School.
final lekkiPickupRoute = TripRoute(const [
  Leg('Ogidi Crescent', [Geo(6.453579, 3.471782), Geo(6.453576, 3.474889)]),
  Leg('Chief Hope Harriman Street', [Geo(6.453576, 3.474889), Geo(6.450372, 3.474933)]),
  Leg('Jerry Iriabe Street', [Geo(6.450372, 3.474933), Geo(6.450372, 3.475987)]),
  Leg('Emeka Nweze Street', [Geo(6.450372, 3.475987), Geo(6.447825, 3.475987)]),
  Leg('Admiralty Way', [Geo(6.447825, 3.475987), Geo(6.447825, 3.470221)]),
], arriveText: 'Pickup on your left');

/// Where Ada stands: on the kerb to the driver's left, a few metres past where the car stops so the pin and car don't overlap.
const lekkiPickupKerb = Geo(6.447765, 3.470021);

/// Ada's drop-off on Africa Lane.
const lekkiDropoff = Geo(6.455984, 3.470221);
