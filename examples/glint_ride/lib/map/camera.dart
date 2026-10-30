import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../trip/geo.dart';
import 'map_look.dart';

/// Camera that frames points inside the part of the map not covered by the banner or sheet.
abstract final class CameraFit {
  static const _tile = 256.0;

  static double _y(double lat) => math.log(math.tan(math.pi / 4 + lat * math.pi / 360));
  static double _lat(double y) => (2 * math.atan(math.exp(y)) - math.pi / 2) * 180 / math.pi;
  static double _log2(double v) => math.log(v) / math.ln2;

  /// Center and zoom that fit [pts] in [size] minus [insets] and [pad]; one place gets [closeZoom].
  static CameraPosition of(
    List<Geo> pts, {
    required Size size,
    required EdgeInsets insets,
    double pad = 48,
    double minZoom = 13.5,
    double maxZoom = 17.6,
    double closeZoom = 17.6,
  }) {
    var s = pts.first.lat, n = s, w = pts.first.lng, e = w;
    for (final p in pts.skip(1)) {
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lng);
      e = math.max(e, p.lng);
    }
    var vw = size.width - insets.horizontal - pad * 2, vh = size.height - insets.vertical - pad * 2;
    // Overlays leave too little room: fit to the whole map rather than zooming in on nothing.
    if (vw < 80 || vh < 80) {
      insets = EdgeInsets.zero;
      vw = size.width - pad * 2;
      vh = size.height - pad * 2;
    }
    final onePlace = Geo(s, w).distanceTo(Geo(n, e)) < 40;
    final zoom = onePlace
        ? closeZoom
        : math
              .min(
                _log2(vw * 360 / (math.max(e - w, 1e-9) * _tile)),
                _log2(vh * 2 * math.pi / (math.max(_y(n) - _y(s), 1e-9) * _tile)),
              )
              .clamp(minZoom, maxZoom);
    final world = _tile * math.pow(2, zoom);
    final cx = (w + e) / 2 + (insets.right - insets.left) / 2 * 360 / world;
    final cy = (_y(n) + _y(s)) / 2 - (insets.bottom - insets.top) / 2 * 2 * math.pi / world;
    return CameraPosition(target: LatLng(_lat(cy), cx), zoom: zoom.toDouble());
  }

  /// Screen point of [g] for a camera, in the map's logical pixels.
  static Offset project(Geo g, CameraPosition cam, Size size) {
    final world = _tile * math.pow(2, cam.zoom);
    final dx = (g.lng - cam.target.longitude) / 360 * world;
    final dy = -(_y(g.lat) - _y(cam.target.latitude)) / (2 * math.pi) * world;
    return Offset(size.width / 2 + dx, size.height / 2 + dy);
  }
}

/// Keeps the trip framed as the car moves and the sheet changes height, without twitching on every fix.
class CameraDirector {
  GoogleMapController? _map;
  CameraPosition? _shown;
  Size size = Size.zero;

  /// Padding given to GoogleMap itself, set once so the logo stays visible; the camera centres inside it.
  EdgeInsets base = EdgeInsets.zero;

  /// What covers the map right now: the top overlay and the sheet at its current height.
  EdgeInsets insets = EdgeInsets.zero;
  bool following = true;

  /// Driver mode: ride behind the car, tilted, heading up, instead of framing the trip.
  bool navigating = false;
  Geo? _navCar;
  double _navHeading = 0;
  Timer? _debounce;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  List<Geo> _frame = const [];

  /// Map is ready: jump straight to the frame, no animation.
  void attach(GoogleMapController c) {
    _map = c;
    if (navigating) {
      if (_navCar != null) c.moveCamera(CameraUpdate.newCameraPosition(_navView(_navCar!, _navHeading)));
      return;
    }
    if (_frame.isEmpty || size.isEmpty) return;
    final want = CameraFit.of(_frame, size: base.deflateSize(size), insets: EdgeInsets.zero);
    _shown = want;
    c.moveCamera(CameraUpdate.newCameraPosition(want));
  }

  /// The map reports where it is; user gestures included.
  void onCameraMove(CameraPosition p) => _shown = p;

  /// New insets from the banner or sheet: reframe soon, after the sheet settles.
  void setInsets(EdgeInsets i) {
    if (navigating) {
      insets = i;
      return;
    }
    if ((i.top - insets.top).abs() < 1 && (i.bottom - insets.bottom).abs() < 1) return;
    insets = i;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 140), () => _go(force: true));
  }

  /// What should stay in view; reframes only when a point is leaving the view or the zoom is clearly off.
  void frame(List<Geo> pts, {bool force = false}) {
    _frame = pts;
    _go(force: force);
  }

  void recenter() {
    following = true;
    if (navigating && _navCar != null) {
      _map?.animateCamera(
        CameraUpdate.newCameraPosition(_navView(_navCar!, _navHeading)),
        duration: const Duration(milliseconds: 600),
      );
      return;
    }
    _go(force: true);
  }

  /// Camera behind the car: heading up and tilted; the map's padding puts the car low on screen so the road ahead fills the view.
  CameraPosition _navView(Geo car, double heading) =>
      CameraPosition(target: ll(car), zoom: 17.8, tilt: 45, bearing: heading);

  /// Follows the car every frame it moves, in driver mode.
  void navigate(Geo car, double heading) {
    _navCar = car;
    _navHeading = heading;
    final map = _map;
    if (!navigating || !following || map == null) return;
    map.moveCamera(CameraUpdate.newCameraPosition(_navView(car, heading)));
  }

  void _go({bool force = false}) {
    if (navigating) return;
    final map = _map;
    if (map == null || !following || _frame.isEmpty || size.isEmpty) return;
    final region = base.deflateSize(size);
    final extra = EdgeInsets.fromLTRB(
      math.max(0, insets.left - base.left),
      math.max(0, insets.top - base.top),
      math.max(0, insets.right - base.right),
      math.max(0, insets.bottom - base.bottom),
    );
    final want = CameraFit.of(_frame, size: region, insets: extra);
    final shown = _shown;
    if (!force && shown != null) {
      final calm = DateTime.now().difference(_lastMove) < const Duration(milliseconds: 1600);
      final zoomOff = (want.zoom - shown.zoom).abs() > 0.3;
      final safe = extra.deflateRect(Offset.zero & region).deflate(20);
      final leaving = _frame.any((g) => !safe.contains(CameraFit.project(g, shown, region)));
      if (calm || (!zoomOff && !leaving)) return;
    }
    _lastMove = DateTime.now();
    _shown = want;
    map.animateCamera(CameraUpdate.newCameraPosition(want), duration: const Duration(milliseconds: 1100));
  }

  void dispose() => _debounce?.cancel();
}
