import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../trip/geo.dart';
import '../ui/theme.dart';

LatLng ll(Geo g) => LatLng(g.lat, g.lng);

/// Colour of road the car has already driven.
const driven = Color(0xFFA7ACB6);

/// Grey full route under a blue line for the road still ahead; glint drives the full one by its id, "route".
Set<Polyline> routeLines(TripRoute r, double along) {
  final all = r.points.map(ll).toList();
  final ahead = r.pointsFrom(along).map(ll).toList();
  Polyline line(String id, List<LatLng> pts, Color c, int w, int z) => Polyline(
    polylineId: PolylineId(id),
    points: pts,
    color: c,
    width: w,
    zIndex: z,
    jointType: JointType.round,
    startCap: Cap.roundCap,
    endCap: Cap.roundCap,
  );
  return {
    line('route-casing', all, Colors.white, 12, 1),
    line('route', all, driven, 7, 2),
    if (ahead.length > 1) line('route-ahead', ahead, blue, 7, 3),
  };
}

/// Pin in the app's blue, Google's own marker shape.
final pickupPin = BitmapDescriptor.defaultMarkerWithHue(HSVColor.fromColor(blue).hue);

/// Marker bitmaps drawn once at the screen's pixel ratio.
class MarkerArt {
  MarkerArt._(this.car, this.start);

  /// Top-down silver car, nose up, so marker rotation equals heading.
  final BitmapDescriptor car;

  /// Small dot where the driver set off.
  final BitmapDescriptor start;

  static Future<MarkerArt> load(double dpr) async => MarkerArt._(
    await BitmapDescriptor.asset(ImageConfiguration(devicePixelRatio: dpr), 'assets/car.png', width: 30),
    await _draw(dpr, const Size(20, 20), (c) {
      const o = Offset(10, 10);
      c.drawCircle(
        o + const Offset(0, 1),
        8,
        Paint()
          ..color = const Color(0x33111318)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      c.drawCircle(o, 8, Paint()..color = Colors.white);
      c.drawCircle(o, 4.5, Paint()..color = ink);
    }),
  );
}

Future<BitmapDescriptor> _draw(double dpr, Size size, void Function(Canvas) paint) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(dpr);
  paint(canvas);
  final img = await rec.endRecording().toImage((size.width * dpr).ceil(), (size.height * dpr).ceil());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), imagePixelRatio: dpr);
}

/// Bounds that hold every point, for fitting the camera.
LatLngBounds boundsOf(Iterable<Geo> pts) {
  var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
  for (final p in pts) {
    s = math.min(s, p.lat);
    n = math.max(n, p.lat);
    w = math.min(w, p.lng);
    e = math.max(e, p.lng);
  }
  return LatLngBounds(southwest: LatLng(s, w), northeast: LatLng(n, e));
}
