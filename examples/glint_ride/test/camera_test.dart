import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glintride/map/camera.dart';
import 'package:glintride/trip/geo.dart';

void main() {
  const size = Size(390, 844);
  final route = lekkiPickupRoute;

  test('framed points land inside the uncovered part of the map', () {
    const insets = EdgeInsets.only(top: 120, bottom: 300);
    final pts = route.ahead(0, route.start);
    final cam = CameraFit.of(pts, size: size, insets: insets);
    for (final p in pts) {
      final o = CameraFit.project(p, cam, size);
      expect(o.dy, inInclusiveRange(insets.top, size.height - insets.bottom));
      expect(o.dx, inInclusiveRange(0, size.width));
    }
  });

  test('zoom rises as the car gets closer', () {
    const insets = EdgeInsets.only(top: 120, bottom: 300);
    final far = CameraFit.of(route.ahead(0, route.start), size: size, insets: insets);
    final near = CameraFit.of(
      route.ahead(route.length - 200, route.pointAt(route.length - 200)),
      size: size,
      insets: insets,
    );
    expect(near.zoom, greaterThan(far.zoom));
  });

  test('one place gets the close zoom', () {
    final cam = CameraFit.of([route.end], size: size, insets: EdgeInsets.zero);
    expect(cam.zoom, 17.6);
  });
}
