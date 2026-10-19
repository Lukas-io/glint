import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../trip/geo.dart';
import '../trip/live.dart';

/// Port the rider app listens on; the iOS simulator shares the Mac's network, so this is the Mac's port.
const linkPort = 8787;

/// A message between the two apps.
sealed class LinkMsg {
  const LinkMsg();

  Map<String, Object?> toJson();

  static LinkMsg? parse(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map) return null;
    return switch (j['t']) {
      'fix' => Fix(
        Geo((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        heading: (j['heading'] as num?)?.toDouble() ?? 0,
        mps: (j['mps'] as num?)?.toDouble() ?? 0,
        pace: (j['pace'] as num?)?.toDouble(),
      ),
      'phase' => PhaseMsg(Phase.values.byName(j['p'] as String)),
      _ => null,
    };
  }
}

/// The driver's position and smoothed speed.
class Fix extends LinkMsg {
  const Fix(this.at, {required this.heading, required this.mps, this.pace});

  final Geo at;
  final double heading;
  final double mps;

  /// The driver's average pace, so both phones show the same ETA.
  final double? pace;

  @override
  Map<String, Object?> toJson() => {
    't': 'fix',
    'lat': at.lat,
    'lng': at.lng,
    'heading': heading,
    'mps': mps,
    if (pace != null) 'pace': pace,
  };
}

/// The driver changed trip phase.
class PhaseMsg extends LinkMsg {
  const PhaseMsg(this.phase);

  final Phase phase;

  @override
  Map<String, Object?> toJson() => {'t': 'phase', 'p': phase.name};
}

/// Rider side: hosts the socket the driver connects to.
class RiderHub {
  final _msgs = StreamController<LinkMsg>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  HttpServer? _server;
  int _peers = 0;

  Stream<LinkMsg> get messages => _msgs.stream;
  Stream<bool> get connected => _connected.stream;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, linkPort, shared: true);
    _server!.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..statusCode = HttpStatus.ok
          ..write('glint Ride rider hub')
          ..close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      _connected.add(++_peers > 0);
      ws.listen((raw) {
        final m = raw is String ? LinkMsg.parse(raw) : null;
        if (m != null) _msgs.add(m);
      }, onDone: () => _connected.add(--_peers > 0));
    });
  }

  Future<void> close() async => _server?.close(force: true);
}

/// Driver side: keeps a socket to the rider open and resends the latest state on reconnect.
class DriverLink {
  DriverLink(this.host);

  /// 10.0.2.2 is the Mac as seen from the Android emulator.
  factory DriverLink.auto() {
    const override = String.fromEnvironment('RIDER_HOST');
    return DriverLink(override.isNotEmpty ? override : (Platform.isAndroid ? '10.0.2.2' : '127.0.0.1'));
  }

  final String host;
  final _connected = StreamController<bool>.broadcast();
  WebSocket? _ws;
  Fix? _lastFix;
  PhaseMsg _phase = const PhaseMsg(Phase.enroute);
  bool _closed = false;

  Stream<bool> get connected => _connected.stream;

  void start() => _connect();

  Future<void> _connect() async {
    while (!_closed) {
      try {
        final ws = await WebSocket.connect('ws://$host:$linkPort').timeout(const Duration(seconds: 3));
        _ws = ws;
        _connected.add(true);
        _send(_phase);
        if (_lastFix != null) _send(_lastFix!);
        await ws.done;
      } catch (_) {
        // Rider app not up yet; retry below.
      }
      _ws = null;
      _connected.add(false);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void sendFix(Fix f) {
    _lastFix = f;
    _send(f);
  }

  void sendPhase(Phase p) {
    _phase = PhaseMsg(p);
    _send(_phase);
  }

  void _send(LinkMsg m) => _ws?.add(jsonEncode(m.toJson()));

  void close() {
    _closed = true;
    _ws?.close();
  }
}
