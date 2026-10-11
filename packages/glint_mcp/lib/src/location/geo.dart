import 'dart:math';

/// A point on the earth in degrees.
typedef LatLng = ({double lat, double lng});

const _earthRadius = 6371000.0;

double _rad(double deg) => deg * pi / 180;
double _deg(double rad) => rad * 180 / pi;

/// Great-circle distance between [a] and [b] in meters.
double distanceMeters(LatLng a, LatLng b) {
  final dLat = _rad(b.lat - a.lat), dLng = _rad(b.lng - a.lng);
  final h = pow(sin(dLat / 2), 2) + cos(_rad(a.lat)) * cos(_rad(b.lat)) * pow(sin(dLng / 2), 2);
  return 2 * _earthRadius * asin(min(1, sqrt(h)));
}

/// Initial compass bearing from [a] to [b], 0 = north, 90 = east.
double bearingDegrees(LatLng a, LatLng b) {
  final y = sin(_rad(b.lng - a.lng)) * cos(_rad(b.lat));
  final x = cos(_rad(a.lat)) * sin(_rad(b.lat)) - sin(_rad(a.lat)) * cos(_rad(b.lat)) * cos(_rad(b.lng - a.lng));
  return (_deg(atan2(y, x)) + 360) % 360;
}

/// [p] moved [meters] toward compass [bearing].
LatLng offset(LatLng p, double meters, double bearing) {
  final d = meters / _earthRadius, b = _rad(bearing), lat1 = _rad(p.lat), lng1 = _rad(p.lng);
  final lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b));
  final lng2 = lng1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2));
  return (lat: _deg(lat2), lng: _deg(lng2));
}

/// A path of points with the distance along it at each point, for finding where a traveller is after any distance.
class GeoPath {
  GeoPath(this.points) : assert(points.length >= 2) {
    var total = 0.0;
    _cumulative.add(0);
    for (var i = 1; i < points.length; i++) {
      total += distanceMeters(points[i - 1], points[i]);
      _cumulative.add(total);
    }
  }

  final List<LatLng> points;
  final _cumulative = <double>[];

  double get lengthMeters => _cumulative.last;

  /// The position and travel heading [meters] along the path, clamped to its ends.
  ({LatLng at, double heading}) at(double meters) {
    final m = meters.clamp(0, lengthMeters).toDouble();
    var i = 1;
    while (i < points.length - 1 && _cumulative[i] < m) {
      i++;
    }
    final a = points[i - 1], b = points[i];
    final span = _cumulative[i] - _cumulative[i - 1];
    final t = span == 0 ? 0.0 : (m - _cumulative[i - 1]) / span;
    return (at: (lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t), heading: bearingDegrees(a, b));
  }

  /// The index of the waypoint nearest to [meters] along the path.
  int waypointAt(double meters) {
    var best = 0;
    for (var i = 1; i < _cumulative.length; i++) {
      if ((_cumulative[i] - meters).abs() < (_cumulative[best] - meters).abs()) best = i;
    }
    return best;
  }

  /// The rest of the path from [meters] on: the point there, then every waypoint after it.
  List<LatLng> pointsFrom(double meters) {
    final m = meters.clamp(0, lengthMeters).toDouble();
    return [at(m).at, for (var i = 0; i < points.length; i++) if (_cumulative[i] > m) points[i]];
  }

  double metersAtWaypoint(int index) => _cumulative[index.clamp(0, _cumulative.length - 1)];
}

/// Points from a GPX file's track, route or waypoint entries, in file order.
List<LatLng> parseGpx(String xml) => [
      for (final m in RegExp(r'<(?:trkpt|rtept|wpt)\b([^>]*)>').allMatches(xml))
        if (_attr(m.group(1)!, 'lat') case final lat?)
          if (_attr(m.group(1)!, 'lon') case final lng?) (lat: lat, lng: lng),
    ];

double? _attr(String attrs, String name) => double.tryParse(RegExp('$name="([^"]+)"').firstMatch(attrs)?.group(1) ?? '');

/// Points from every `<coordinates>` block of a KML file (`lng,lat[,alt]` tuples).
List<LatLng> parseKml(String xml) => [
      for (final block in RegExp(r'<coordinates>([\s\S]*?)</coordinates>').allMatches(xml))
        for (final tuple in block.group(1)!.trim().split(RegExp(r'\s+')))
          if (tuple.split(',') case [final lng, final lat, ...])
            if (double.tryParse(lat) case final la?)
              if (double.tryParse(lng) case final lo?) (lat: la, lng: lo),
    ];

/// Points from a Google encoded polyline, as directions APIs return them.
List<LatLng> decodePolyline(String encoded) {
  final out = <LatLng>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var result = 0, shift = 0, b = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && index < encoded.length);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (index < encoded.length) {
    lat += next();
    if (index >= encoded.length) break;
    lng += next();
    out.add((lat: lat / 1e5, lng: lng / 1e5));
  }
  return out;
}

/// A random offset of about [meters] (normal, so most fixes land within it), for GPS noise.
LatLng jitter(LatLng p, double meters, Random rng) {
  if (meters <= 0) return p;
  final r = (sqrt(-2 * log(1 - rng.nextDouble())) * cos(2 * pi * rng.nextDouble())).abs() * meters / 2;
  return offset(p, r, rng.nextDouble() * 360);
}
