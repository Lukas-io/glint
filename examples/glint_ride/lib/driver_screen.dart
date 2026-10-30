import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:sprung/sprung.dart';

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
import 'ui/theme.dart';

/// Tunde's phone: directions to Ada, and the buttons that move the trip along.
class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> with SingleTickerProviderStateMixin {
  final route = lekkiPickupRoute;
  final link = DriverLink.auto();
  final speed = SpeedTracker();
  final eta = EtaClock();
  final camera = CameraDirector()..navigating = true;

  /// Car moves repaint only the map, not the whole screen.
  final _carTick = ValueNotifier(0);
  late final CarFollower car = CarFollower(
    this,
    route,
    onTick: () {
      // While the camera rides with the car, the map only needs a rebuild when the grey road grows.
      final key = _pinned ? (car.along / _greyStep).floor() : -1 - _carTick.value;
      if (key != _lastKey) {
        _lastKey = key;
        _carTick.value++;
      }
      camera.navigate(car.position, car.heading);
    },
  );
  int _lastKey = 0;

  /// The driver's road greys out in 10 m steps; the car covers the gap, and the map updates far less often.
  static const _greyStep = 10.0;

  /// Car drawn as a fixed overlay while the camera follows it, so each frame moves only the camera.
  bool _pinned = true;
  Timer? _pinAgain;
  final _subs = <StreamSubscription<Object?>>[];
  MarkerArt? art;
  Geo target = lekkiPickupRoute.start;
  bool linked = false;
  bool lost = false;
  double _bannerH = 0;
  String? gpsProblem;
  Phase phase = Phase.enroute;
  DateTime? waitStart;
  DateTime? tripAt;
  Timer? _tick;

  /// Android hands out a fix only every 5 s by default, which makes the car stop and surge; ask for one every half second.
  static final LocationSettings _gpsSettings = Platform.isAndroid
      ? AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(milliseconds: 500),
        )
      : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);

  /// Set with --dart-define=SIM=true to drive the route without a GPS feed.
  static const _sim = bool.fromEnvironment('SIM');

  @override
  void initState() {
    super.initState();
    car.fix(route.start, 0);
    _reframe(force: true);
    _subs.add(link.connected.listen((v) => setState(() => linked = v)));
    link.start();
    _sim ? _simulate() : _listenGps();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final a = await MarkerArt.load(MediaQuery.devicePixelRatioOf(context));
      if (mounted) setState(() => art = a);
    });
  }

  Future<void> _listenGps() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => gpsProblem = 'Location is off for glint Ride');
      return;
    }
    _subs.add(
      Geolocator.getPositionStream(locationSettings: _gpsSettings).listen(
        (p) => _onFix(Geo(p.latitude, p.longitude), DateTime.now(), p.speed),
        onError: (Object e) => setState(() => gpsProblem = 'No GPS signal'),
      ),
    );
  }

  void _simulate() {
    var along = 0.0;
    _subs.add(
      Stream<void>.periodic(const Duration(seconds: 1)).listen((_) {
        along = (along + 8.3) % route.length;
        _onFix(route.pointAt(along), DateTime.now(), 8.3);
      }),
    );
  }

  void _onFix(Geo g, DateTime at, double reported) {
    speed.add(g, at, reported: reported);
    eta.add(speed.mps, at);
    target = g;
    gpsProblem = null;
    car.fix(g, speed.mps);
    link.sendFix(Fix(g, heading: route.headingAt(route.snap(g).along), mps: speed.mps, pace: eta.pace));
    _reframe();
    setState(() {});
  }

  void _setPhase(Phase p) {
    setState(() {
      phase = p;
      waitStart = p == Phase.arrived ? DateTime.now() : null;
      tripAt = p == Phase.onTrip ? DateTime.now() : null;
      _tick?.cancel();
      if (p == Phase.arrived) _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    });
    link.sendPhase(p);
    eta.reset();
    _reframe(force: true);
  }

  /// En route: the car and the road ahead, so the next turn is in view; at pickup: close in; on trip: car and drop-off.
  void _reframe({bool force = false}) => camera.frame(switch (phase) {
    Phase.enroute => route.ahead(route.snap(target).along, target),
    Phase.arrived => [route.end],
    Phase.onTrip => [target, lekkiDropoff],
  }, force: force);

  EdgeInsets _cover(double sheet) => EdgeInsets.only(
    top: MediaQuery.paddingOf(context).top + 4 + (phase == Phase.enroute ? _bannerH : 0),
    bottom: sheet,
  );

  double _sheetH = 0;

  /// The map centres the car in its padded area: pad below the banner and above the sheet, plus extra on top so the car sits low and the road ahead shows.
  void _onSheet(double h) {
    _sheetH = h;
    if (_bannerH == 0) return;
    final cover = _cover(h);
    final free = MediaQuery.sizeOf(context).height - cover.vertical;
    final pad = cover.copyWith(top: cover.top + free * 0.3);
    if ((pad.top - camera.base.top).abs() > 1 || (pad.bottom - camera.base.bottom).abs() > 1) {
      setState(() => camera.base = pad);
    }
    camera.setInsets(cover);
  }

  void _onBanner(double h) {
    _bannerH = h;
    if (_sheetH > 0) _onSheet(_sheetH);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    _pinAgain?.cancel();
    car.dispose();
    _carTick.dispose();
    camera.dispose();
    link.close();
    super.dispose();
  }

  LiveBar _live(LiveStats s) {
    final now = DateTime.now();
    switch (phase) {
      case Phase.arrived:
        final waited = now.difference(waitStart ?? now);
        final left = freeWaiting - waited;
        return LiveBar(
          title: 'Waiting for Ada',
          mood: 'wait',
          trailing: fmtTimer(waited),
          left: left.isNegative ? 'Free waiting is over' : 'Free waiting · ${fmtTimer(left)} left',
          right: 'Ada knows you’re here',
        );
      case Phase.onTrip:
        return LiveBar(
          title: 'Trip to Africa Lane',
          mood: 'trip',
          trailing: fmtClock((tripAt ?? now).add(const Duration(minutes: 9))),
          left: 'Ada is in the car',
          right: 'Africa Lane',
        );
      case Phase.enroute:
        final d = Directions.of(route, s.snap.along);
        return LiveBar(
          title: s.remaining < 30
              ? 'You’re at the pickup'
              : s.arrivingNow
              ? 'Ada is on your left'
              : 'Ada in ${eta.minutes(s)} min',
          mood: s.remaining < 30
              ? 'here'
              : s.arrivingNow
              ? 'now'
              : 'eta',
          trailing: fmtClock(eta.arrival(s, now)),
          left:
              gpsProblem ??
              (!linked
                  ? 'Connecting to Ada…'
                  : s.remaining < 30
                  ? 'At the pickup'
                  : '${fmtDistance(s.remaining)}${s.speedKmh < 2 ? '' : ' · ${s.speedKmh.round()} km/h'}'),
          right: d.then?.text ?? d.text,
        );
    }
  }

  Widget _actions() => AnimatedSwitcher(
    duration: const Duration(milliseconds: 420),
    switchInCurve: Sprung(28),
    transitionBuilder: (child, a) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: child),
    ),
    child: SizedBox(key: ValueKey(phase), width: double.infinity, child: _actionFor()),
  );

  Widget _actionFor() => switch (phase) {
    Phase.enroute => PrimaryButton('Arrived', onTap: () => _setPhase(Phase.arrived)),
    Phase.arrived => Row(
      children: [
        TextAction('Rider not here', onTap: () => _setPhase(Phase.enroute)),
        const SizedBox(width: 12),
        Expanded(child: PrimaryButton('Start trip', onTap: () => _setPhase(Phase.onTrip))),
      ],
    ),
    Phase.onTrip => PrimaryButton('End trip', onTap: () => _setPhase(Phase.enroute)),
  };

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
      if (!_pinned)
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
    final s = LiveStats.of(route, target, speed.mps, pace: eta.pace);
    final live = _live(s);
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
                step: _greyStep,
                onUserMove: () => setState(() {
                  _pinAgain?.cancel();
                  lost = camera.following = _pinned = false;
                }),
              ),
            ),
          ),
          if (_pinned && art != null)
            Positioned.fill(
              child: IgnorePointer(child: PinnedCar(padding: camera.base)),
            ),
          Positioned(
            left: 12,
            right: 12,
            top: top + 4,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, -0.4), end: Offset.zero).animate(a),
                  child: child,
                ),
              ),
              child: phase == Phase.enroute
                  ? HeightReporter(
                      key: const ValueKey('banner'),
                      onHeight: _onBanner,
                      child: DirectionsBanner(Directions.of(route, s.snap.along)),
                    )
                  : const SizedBox(key: ValueKey('none')),
            ),
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
                    // Swap back to the fixed car once the camera has flown back to it.
                    _pinAgain = Timer(const Duration(milliseconds: 650), () => setState(() => _pinned = true));
                  },
                ),
                HeightReporter(
                  onHeight: _onSheet,
                  child: RideSheet(
                    more: [
                      live,
                      const PersonCard(
                        initials: 'AO',
                        rating: '4.8',
                        name: 'Ada O.',
                        sub: 'To Africa Lane',
                        big: '₦4,800',
                        bigSub: 'Card · 9 min trip',
                        message: 'Message Ada',
                        call: 'Call Ada',
                      ),
                      _actions(),
                    ],
                    children: [live, _actions()],
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

/// White turn-by-turn card: the next maneuver big, the one after it underneath.
class DirectionsBanner extends StatelessWidget {
  const DirectionsBanner(this.d, {super.key});

  final Directions d;

  static IconData _icon(ManeuverKind? k) => switch (k) {
    ManeuverKind.turnRight => LucideIcons.cornerUpRight,
    ManeuverKind.turnLeft => LucideIcons.cornerUpLeft,
    ManeuverKind.arrive => LucideIcons.mapPin,
    null => LucideIcons.arrowUp,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x24111318), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            layoutBuilder: (cur, prev) => Stack(children: [...prev, ?cur]),
            child: Padding(
              key: ValueKey(d.text),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Row(
                children: [
                  Icon(_icon(d.kind), size: 34, color: blue),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.distance == null ? 'Arriving' : fmtDistance(d.distance!),
                          style: t(26, w: FontWeight.w700, h: 31),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          d.text,
                          style: t(15, w: FontWeight.w500, c: grey, h: 20),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (d.then != null)
            Container(
              color: soft,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                children: [
                  Text('Then', style: t(14, c: grey, h: 18)),
                  const SizedBox(width: 10),
                  Icon(_icon(d.then!.kind), size: 16, color: ink),
                  const SizedBox(width: 10),
                  Text(d.then!.text, style: t(14, w: FontWeight.w600, h: 18)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The driver's car where the camera holds it: centre of the padded map, nose up, laid flat into the 45° tilt.
class PinnedCar extends StatelessWidget {
  const PinnedCar({super.key, required this.padding});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final x = padding.left + (c.maxWidth - padding.horizontal) / 2;
        final y = padding.top + (c.maxHeight - padding.vertical) / 2;
        return Stack(
          children: [
            Positioned(
              left: x - 15,
              top: y - 25,
              width: 30,
              height: 50,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateX(math.pi / 4),
                child: Image.asset('assets/car.png', width: 30, filterQuality: FilterQuality.medium),
              ),
            ),
          ],
        );
      },
    );
  }
}
