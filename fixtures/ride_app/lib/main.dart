import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() => runApp(const RideApp());

class RideApp extends StatelessWidget {
  const RideApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Ride Fixture',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const RidePage(),
      );
}

class RidePage extends StatefulWidget {
  const RidePage({super.key});

  @override
  State<RidePage> createState() => _RidePageState();
}

class _RidePageState extends State<RidePage> {
  static const _start = LatLng(6.5244, 3.3792);
  StreamSubscription<Position>? _positions;
  GoogleMapController? _map;
  Position? _position;
  int _updates = 0;
  String _status = 'Starting';

  @override
  void initState() {
    super.initState();
    _listen();
  }

  Future<void> _listen() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Location services are off');
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission denied');
      return;
    }
    setState(() => _status = 'Waiting for a location');
    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    ).listen((p) {
      setState(() {
        _position = p;
        _updates++;
        _status = 'Tracking';
      });
      _map?.animateCamera(CameraUpdate.newLatLng(LatLng(p.latitude, p.longitude)));
    });
  }

  @override
  void dispose() {
    _positions?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _position;
    final here = p == null ? _start : LatLng(p.latitude, p.longitude);
    return Scaffold(
      appBar: AppBar(title: const Text('Ride Fixture')),
      body: Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(target: _start, zoom: 15),
              markers: {
                if (p != null) Marker(markerId: const MarkerId('me'), position: here, infoWindow: const InfoWindow(title: 'You')),
              },
              onMapCreated: (c) => _map = c,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(_status, style: Theme.of(context).textTheme.titleMedium),
                Text(p == null ? 'No position yet' : 'Position ${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}'),
                Text(p == null
                    ? 'Updates 0'
                    : 'Updates $_updates · speed ${p.speed.toStringAsFixed(1)} m/s · heading ${p.heading.toStringAsFixed(0)}°'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
