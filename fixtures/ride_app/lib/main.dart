import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'wallet.dart';

void main() => runApp(const RideApp());

class RideApp extends StatelessWidget {
  const RideApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Ride Fixture',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const _Tabs(),
      );
}

class _Tabs extends StatefulWidget {
  const _Tabs();

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _tab, children: const [RidePage(), WalletTab()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.local_taxi), label: 'Ride'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
          ],
        ),
      );
}

class RidePage extends StatefulWidget {
  const RidePage({super.key});

  @override
  State<RidePage> createState() => _RidePageState();
}

class _RidePageState extends State<RidePage> {
  static const _start = LatLng(6.5244, 3.3792);
  static const _dropoff = LatLng(6.4281, 3.4219);
  StreamSubscription<Position>? _positions;
  GoogleMapController? _map;
  Position? _position;
  int _updates = 0;
  String _status = 'Starting';
  String _access = 'Permission not checked';
  bool _driver = false;
  LatLng? _driverAt;
  String _trip = 'No driver yet';
  Timer? _follow;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  /// The relay on the host: the Android emulator reaches it at 10.0.2.2; `--dart-define=RELAY=host:port` for a phone.
  static const _relayFlag = String.fromEnvironment('RELAY');
  static final _relay = Uri.parse('http://${_relayFlag.isNotEmpty ? _relayFlag : (Platform.isAndroid ? '10.0.2.2:8790' : '127.0.0.1:8790')}');

  @override
  void initState() {
    super.initState();
    _listen();
    _follow = Timer.periodic(const Duration(seconds: 1), (_) => _driver ? null : _pollDriver());
  }

  void _tapped(String marker) => setState(() => _trip = 'Tapped $marker');

  Future<void> _sendDriver(Position p) async {
    try {
      final req = await _http.postUrl(_relay.resolve('/driver'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'lat': p.latitude, 'lng': p.longitude, 'heading': p.heading}));
      await (await req.close()).drain<void>();
    } on Object catch (e) {
      setState(() => _trip = 'Relay unreachable: $e');
    }
  }

  Future<void> _pollDriver() async {
    try {
      final res = await (await _http.getUrl(_relay.resolve('/driver'))).close();
      final body = await utf8.decodeStream(res);
      if (res.statusCode != 200) {
        setState(() => _trip = 'No driver yet');
        return;
      }
      final d = jsonDecode(body) as Map<String, dynamic>;
      final at = LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble());
      final meters = Geolocator.distanceBetween(at.latitude, at.longitude, _start.latitude, _start.longitude);
      setState(() {
        _driverAt = at;
        _trip = meters <= 50 ? 'Driver arrived' : 'Driver ${meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m'} away';
      });
    } on Object catch (e) {
      setState(() => _trip = 'Relay unreachable: $e');
    }
  }

  Future<void> _listen() async {
    await _positions?.cancel();
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Location services are off');
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    final accuracy = permission == LocationPermission.denied || permission == LocationPermission.deniedForever
        ? null
        : await Geolocator.getLocationAccuracy();
    setState(() => _access = 'Permission ${permission.name}${accuracy == null ? '' : ' · ${accuracy.name}'}');
    if (accuracy == null) {
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
      if (_driver) _sendDriver(p);
      _map?.animateCamera(CameraUpdate.newLatLng(LatLng(p.latitude, p.longitude)));
    }, onError: (Object e) => setState(() => _status = 'Location stopped: $e'));
  }

  @override
  void dispose() {
    _follow?.cancel();
    _http.close(force: true);
    _positions?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _position;
    final here = p == null ? _start : LatLng(p.latitude, p.longitude);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride Fixture'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Rider')),
                ButtonSegment(value: true, label: Text('Driver')),
              ],
              selected: {_driver},
              onSelectionChanged: (v) => setState(() {
                _driver = v.first;
                _driverAt = null;
                _trip = _driver ? 'Sharing your position' : 'No driver yet';
              }),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(target: _start, zoom: 15),
              markers: {
                if (p != null) Marker(markerId: const MarkerId('me'), position: here, infoWindow: const InfoWindow(title: 'You')),
                Marker(markerId: const MarkerId('pickup'), position: _start, infoWindow: const InfoWindow(title: 'Pickup'), onTap: () => _tapped('Pickup')),
                Marker(markerId: const MarkerId('dropoff'), position: _dropoff, infoWindow: const InfoWindow(title: 'Drop-off'), onTap: () => _tapped('Drop-off')),
                if (_driverAt != null) Marker(markerId: const MarkerId('driver'), position: _driverAt!, infoWindow: const InfoWindow(title: 'Driver')),
              },
              polylines: {
                const Polyline(polylineId: PolylineId('trip'), points: [_start, LatLng(6.4550, 3.3941), _dropoff], width: 5),
              },
              circles: {
                const Circle(circleId: CircleId('pickup_zone'), center: _start, radius: 150, strokeWidth: 1),
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
                Row(
                  children: [
                    Expanded(child: Text(_status, style: Theme.of(context).textTheme.titleMedium)),
                    TextButton(onPressed: _listen, child: const Text('Try again')),
                  ],
                ),
                Text(_access),
                Text(_trip),
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
