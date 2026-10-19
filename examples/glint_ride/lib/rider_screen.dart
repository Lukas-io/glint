import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'link/link.dart';
import 'map/camera.dart';
import 'map/follow.dart';
import 'map/map_look.dart';
import 'map/ride_map.dart';
import 'trip/geo.dart';
import 'trip/live.dart';
import 'ui/live_bar.dart';
import 'ui/measure.dart';
import 'ui/parts.dart';
import 'ui/sheet.dart';

/// Ada's phone: watches Tunde drive to the pickup.
class RiderScreen extends StatefulWidget {
  const RiderScreen({super.key});

  @override
  State<RiderScreen> createState() => _RiderScreenState();
}

class _RiderScreenState extends State<RiderScreen> with SingleTickerProviderStateMixin {
  final route = lekkiPickupRoute;
  final hub = RiderHub();
  final camera = CameraDirector();

  /// Car moves repaint only the map, not the whole screen.
  final _carTick = ValueNotifier(0);
  late final CarFollower car = CarFollower(this, route, onTick: () => _carTick.value++);
  final _subs = <StreamSubscription<Object?>>[];
  MarkerArt? art;
  Geo target = lekkiPickupRoute.start;
  double mps = 0;

  /// The driver's average pace, for an ETA that matches the driver's phone.
  double? driverPace;
  final eta = EtaClock();
  bool linked = false;
  bool lost = false;
  Phase phase = Phase.enroute;
  DateTime? arrivedAt;
  DateTime? tripAt;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    car.fix(route.start, 0);
    _subs.add(hub.connected.listen((v) => setState(() => linked = v)));
    _subs.add(hub.messages.listen(_onMsg));
    hub.start();
    _reframe(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final a = await MarkerArt.load(MediaQuery.devicePixelRatioOf(context));
      if (mounted) setState(() => art = a);
    });
  }

  void _onMsg(LinkMsg m) {
    switch (m) {
      case Fix():
        target = m.at;
        mps = m.mps;
        driverPace = m.pace;
        car.fix(m.at, m.mps);
        _reframe();
      case PhaseMsg(:final phase):
        _setPhase(phase);
    }
    setState(() {});
  }

  void _setPhase(Phase p) {
    if (p == phase) return;
    phase = p;
    eta.reset();
    arrivedAt = p == Phase.arrived ? DateTime.now() : arrivedAt;
    tripAt = p == Phase.onTrip ? DateTime.now() : null;
    _tick?.cancel();
    if (p == Phase.arrived) _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    _reframe(force: true);
  }

  /// En route: the car and the road still ahead; arrived: close on the pickup; on trip: car and drop-off.
  void _reframe({bool force = false}) => camera.frame(switch (phase) {
    Phase.enroute => route.ahead(route.snap(target).along, target),
    Phase.arrived => [route.end],
    Phase.onTrip => [target, lekkiDropoff],
  }, force: force);

  void _onSheet(double h) {
    final cover = EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 60, bottom: h);
    if (camera.base == EdgeInsets.zero) setState(() => camera.base = cover);
    camera.setInsets(cover);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    car.dispose();
    _carTick.dispose();
    camera.dispose();
    hub.close();
    super.dispose();
  }

  LiveBar _live() {
    final now = DateTime.now();
    switch (phase) {
      case Phase.arrived:
        final left = freeWaiting - now.difference(arrivedAt ?? now);
        return LiveBar(
          title: 'Tunde is here',
          mood: 'here',
          trailing: fmtClock(arrivedAt ?? now),
          left: left.isNegative ? 'Free waiting is over' : 'Free waiting · ${fmtTimer(left)} left',
          right: 'Look for KJA 482 AB',
        );
      case Phase.onTrip:
        return LiveBar(
          title: 'On the way to Africa Lane',
          mood: 'trip',
          trailing: fmtClock((tripAt ?? now).add(const Duration(minutes: 9))),
          left: 'Trip started · 9 min',
          right: 'Africa Lane',
        );
      case Phase.enroute:
        final s = LiveStats.of(route, target, mps, pace: driverPace);
        final near = s.remaining < 150;
        final pace = near ? ' · slowing down' : (s.speedKmh < 2 ? '' : ' · ${s.speedKmh.round()} km/h');
        return LiveBar(
          title: s.remaining < 30
              ? 'Tunde is here'
              : s.arrivingNow
              ? 'Arriving now'
              : 'Arriving in ${eta.minutes(s)} min',
          mood: s.remaining < 30
              ? 'here'
              : s.arrivingNow
              ? 'now'
              : 'eta',
          trailing: fmtClock(eta.arrival(s, now)),
          left: !linked
              ? 'Connecting to Tunde…'
              : s.remaining < 30
              ? 'At the pickup'
              : '${fmtDistance(s.remaining)} away$pace',
          right: near ? 'Look for KJA 482 AB' : route.legs[s.snap.leg].road,
        );
    }
  }

  Set<Marker> _markers() {
    final a = art;
    if (a == null) return {};
    return {
      Marker(
        markerId: const MarkerId('start'),
        position: ll(route.start),
        icon: a.start,
        anchor: const Offset(0.5, 0.5),
      ),
      Marker(markerId: const MarkerId('pickup'), position: ll(lekkiPickupKerb), icon: pickupPin, zIndexInt: 1),
      Marker(
        markerId: const MarkerId('car'),
        position: ll(car.position),
        icon: a.car,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        rotation: car.heading,
        zIndexInt: 2,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final live = _live();
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ValueListenableBuilder(
              valueListenable: _carTick,
              builder: (context, _, _) => RideMap(
                route: route,
                markers: _markers(),
                director: camera,
                along: car.along,
                onUserMove: () => setState(() => lost = camera.following = false),
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: top + 8,
            child: const MapButton(LucideIcons.x, label: 'Close'),
          ),
          Positioned(
            right: 16,
            top: top + 8,
            child: const MapButton(LucideIcons.shield, label: 'Safety'),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                RecenterButton(
                  visible: lost,
                  onTap: () {
                    setState(() => lost = false);
                    camera.recenter();
                  },
                ),
                HeightReporter(
                  onHeight: _onSheet,
                  child: RideSheet(
                    more: [
                      live,
                      const PersonCard(
                        initials: 'TA',
                        rating: '4.9',
                        name: 'Tunde A.',
                        sub: 'Top-rated driver',
                        big: 'KJA 482 AB',
                        bigSub: 'Silver Toyota Corolla',
                        message: 'Any pickup notes?',
                        call: 'Call Tunde',
                      ),
                      const ActionRows([(LucideIcons.share, 'Share trip'), (LucideIcons.x, 'Cancel ride')]),
                    ],
                    children: [
                      live,
                      const CompactPerson(
                        initials: 'TA',
                        top: 'KJA 482 AB',
                        sub: 'Tunde A. · Silver Toyota Corolla',
                        call: 'Call Tunde',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
