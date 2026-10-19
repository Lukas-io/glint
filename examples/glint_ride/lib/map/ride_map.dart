import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../trip/geo.dart';
import 'camera.dart';
import 'map_look.dart';

/// The Google map both apps sit on: Google's default look, the route, and a camera run by [director].
class RideMap extends StatelessWidget {
  const RideMap({
    super.key,
    required this.route,
    required this.markers,
    required this.director,
    required this.onUserMove,
    required this.along,
    this.step = 4,
  });

  final TripRoute route;
  final Set<Marker> markers;
  final CameraDirector director;

  /// Where the car is drawn; road behind it greys out, in [step] metre steps so the map isn't flooded with line updates.
  final double along;

  /// Metres between grey-road updates.
  final double step;

  /// The user touched the map, so the camera stops following until re-centred.
  final VoidCallback onUserMove;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        director.size = c.biggest;
        return Listener(
          onPointerDown: (_) => onUserMove(),
          child: GoogleMap(
            initialCameraPosition: CameraPosition(target: ll(route.pointAt(route.length / 2)), zoom: 15.5),
            padding: director.base,
            polylines: routeLines(route, (along / step).floorToDouble() * step),
            markers: markers,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            onMapCreated: director.attach,
            onCameraMove: director.onCameraMove,
          ),
        );
      },
    );
  }
}
