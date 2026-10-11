import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../interaction/emulator_control.dart' show EmulatorInstance;
import '../../location/geo.dart';
import '../../location/location_backend.dart';
import '../../location/location_permission.dart';
import '../../location/location_player.dart';
import '../../location/location_prompt.dart';
import '../../media/gallery.dart' show MediaDevice;
import '../../media/permissions.dart' show PermissionRefused, PermissionUnsupported;
import '../../perception/runner_native_reader.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

const _ops = ['set', 'get', 'clear', 'route', 'pause', 'resume', 'stop', 'seek', 'permission', 'services', 'answer'];
const _feeding = {'set', 'route', 'seek', 'resume'};

/// `location` sets where the device thinks it is, or drives it along a route in the background while the agent keeps using the app.
class LocationTool extends GlintTool {
  const LocationTool();

  @override
  Tool get definition => Tool(
        name: 'location',
        description: 'Simulated GPS on the iOS simulator, Android emulator or a paired iPhone. op: '
            'set (one position: at "lat,lng"), get (what glint feeds now, route progress, and on Android whether the app is listening), '
            'clear (stop simulating), route (travel points, a GPX or KML file, or an encoded polyline in the background, at speedKmh or over durationSec; '
            'loop, jitterM noise, dropout lost fixes), pause, resume, stop, seek (progress 0 to 1, meters or waypoint), '
            'permission (value: whileUsing | always | approximate | deny | reset, without a prompt), services (value: on | off, Android), '
            'answer (tap the open system location prompt: choice whileUsing | once | deny | always | keepWhileUsing, precise). '
            'Replies say the app\'s permission when glint can read it. errorKind: invalidArgument, deviceGone, deviceClaimed, unsupportedBackendAction, targetNotFound, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: _ops.join(' | ')),
            'device': Schema.string(description: 'Simulator UDID, iPhone UDID or emulator serial. Default: the attached device.'),
            'at': Schema.string(description: 'set: "lat,lng" in degrees, e.g. "6.5244,3.3792".'),
            'heading': Schema.num(description: 'set: compass heading in degrees (Android only).'),
            'points': Schema.list(description: 'route: waypoints as "lat,lng" strings, in order.'),
            'file': Schema.string(description: 'route: a host GPX or KML file.'),
            'polyline': Schema.string(description: 'route: a Google encoded polyline, as directions APIs return.'),
            'speedKmh': Schema.num(description: 'route: travel speed. Default 30. set: the reported speed (Android only).'),
            'durationSec': Schema.num(description: 'route: travel the whole route in this many seconds instead of at speedKmh.'),
            'intervalMs': Schema.int(description: 'route: time between fixes. Default 1000; at least 500 on the iOS simulator, 2000 on an iPhone.'),
            'loop': Schema.bool(description: 'route: start over at the end instead of stopping.'),
            'jitterM': Schema.num(description: 'route: GPS noise, about this many meters. Default 0.'),
            'dropout': Schema.num(description: 'route: share of fixes lost, 0 to 1. Default 0.'),
            'progress': Schema.num(description: 'seek, or route start: 0 to 1 along the route.'),
            'meters': Schema.num(description: 'seek: meters along the route.'),
            'waypoint': Schema.int(description: 'seek: waypoint index, 0 = start.'),
            'value': Schema.string(description: 'permission: whileUsing | always | approximate | deny | reset. services: on | off.'),
            'choice': Schema.string(description: 'answer: whileUsing | once | deny | always | keepWhileUsing.'),
            'precise': Schema.bool(description: 'answer: pick precise (true) or approximate (false) location first, where the prompt offers it.'),
            'appId': Schema.string(description: 'permission: bundle id or package. Default: the attached app.'),
          },
          required: ['op'],
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = args['op'] as String?;
    if (!_ops.contains(op)) return _bad('op must be ${_ops.join(', ')}; got ${op ?? 'nothing'}');
    final failure = <StructuredResponse>[];
    final backend = await _backend(session, args, failure);
    if (backend == null) return failure.single;
    if (backend is AndroidEmulatorLocation && _feeding.contains(op)) {
      final emulator = await EmulatorInstance.locate(backend.id, adbPath: backend.adbPath);
      if (emulator != null && emulator.grpc == null) {
        return StructuredResponse.error(
          summary: 'cannot set the location of ${emulator.label}: it has no gRPC control',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: emulator.noControlReason,
          nextSteps: emulator.controlSteps,
        );
      }
    }
    final app = session.isAttached && session.device.id == backend.id ? session.attachedBundleId : null;
    try {
      return switch (op) {
        'set' => await _set(backend, args, app),
        'get' => await _get(backend, app),
        'clear' => await _clear(backend),
        'route' => await _route(backend, args, app),
        'seek' => await _seek(backend, args),
        'permission' => await _permission(backend, args, app),
        'services' => await _services(backend, args),
        'answer' => await _answer(session, backend, args, app),
        _ => await _control(backend, op!),
      };
    } on PermissionUnsupported catch (e) {
      return StructuredResponse.error(
        summary: 'cannot set that on ${backend.label}: ${e.reason}',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        nextSteps: e.nextSteps,
      );
    } on PermissionRefused catch (e) {
      return StructuredResponse.error(
        summary: e.unknownApp ? '${args['appId'] ?? app} is not installed on ${backend.label}' : 'the device refused the permission change',
        errorKind: e.notDeclared || e.unknownApp ? GlintErrorKind.invalidArgument : GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [
          if (e.notDeclared) 'the app must declare the permission in its AndroidManifest.xml; this is an app bug or a missing feature',
          if (e.unknownApp) 'pass appId:"<the installed package>"',
        ],
      );
    } on LocationFailed catch (e) {
      return StructuredResponse.error(
        summary: '${backend.label}: ${e.summary}',
        errorKind: GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [
          if (backend is IosDeviceLocation) 'check the iPhone is unlocked, paired and has Developer Mode on',
          'check the device is running, then retry',
        ],
      );
    }
  }

  StructuredResponse _bad(String summary, {String? detail, List<String> nextSteps = const []}) =>
      StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument, detail: detail, nextSteps: nextSteps);

  Future<LocationBackend?> _backend(GlintSession session, Map<String, Object?> args, List<StructuredResponse> failure) async {
    final given = (args['device'] as String?)?.trim();
    final attached = session.isAttached ? session.device : null;
    final id = given != null && given.isNotEmpty ? given : attached?.id;
    if (id == null) {
      failure.add(StructuredResponse.error(
        summary: 'no device to set the location on: glint is not attached and no device was given',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['call `attach` (device mode works), or pass device:"<udid or emulator serial>"'],
      ));
      return null;
    }
    if (!session.hasApp(id)) {
      final claim = DeviceClaims().heldByOther(id);
      if (claim != null) {
        failure.add(StructuredResponse.error(
          summary: 'device $id is driven by another glint session',
          errorKind: GlintErrorKind.deviceClaimed,
          detail: claim.describe,
          nextSteps: const ['pass the device this session attached, or ask the user before touching it'],
        ));
        return null;
      }
    }
    final isAndroid = !RegExp(r'^[0-9A-Fa-f-]{25,36}$').hasMatch(id);
    if (isAndroid && !id.startsWith('emulator-')) {
      failure.add(StructuredResponse.error(
        summary: 'location simulation works on Android emulators, not physical Android phones',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'a phone takes mock locations only from an app selected as its mock location app, and glint installs nothing',
        nextSteps: const ['run the flow on an Android emulator', 'or use an iOS simulator or a paired iPhone'],
      ));
      return null;
    }
    final physical = attached is IosDevice && attached.id == id || isPhysicalIosUdid(id);
    final adbPath = attached is AndroidDevice ? attached.adbPath : (resolveAdbPath(null) ?? 'adb');
    final backend = LocationBackend.forDevice(id, physical: physical, adbPath: adbPath);
    if (backend is IosSimulatorLocation && !await const SimControl().isBooted(id)) {
      failure.add(StructuredResponse.error(
        summary: 'simulator $id is not booted',
        errorKind: GlintErrorKind.deviceGone,
        nextSteps: ['attach device:"$id" boots it'],
      ));
      return null;
    }
    return backend;
  }

  LatLng? _parsePoint(Object? raw) {
    final (Object? a, Object? b) = switch (raw) {
      String s when s.contains(',') => (s.split(',')[0], s.split(',')[1]),
      List l when l.length >= 2 => (l[0], l[1]),
      Map m => (m['lat'] ?? m['latitude'], m['lng'] ?? m['lon'] ?? m['longitude']),
      _ => (null, null),
    };
    final lat = double.tryParse('$a'.trim()), lng = double.tryParse('$b'.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return null;
    return (lat: lat, lng: lng);
  }

  String _fmt(LatLng p) => '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}';

  String _km(double meters) => meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';

  String _dur(Duration d) {
    if (d.inMinutes >= 60) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inSeconds >= 90) return '${(d.inSeconds / 60).round()} min';
    return '${d.inSeconds} s';
  }

  Map<String, Object?> _fixData(Fix f) => {
        'lat': double.parse(f.at.lat.toStringAsFixed(6)),
        'lng': double.parse(f.at.lng.toStringAsFixed(6)),
        if (f.speed != null) 'speedKmh': double.parse((f.speed! * 3.6).toStringAsFixed(1)),
        if (f.heading != null) 'heading': f.heading!.round(),
      };

  /// Warnings from what the device reports about location, so a fix the app never sees does not pass silently.
  MediaDevice _mediaDevice(LocationBackend backend) => backend is AndroidEmulatorLocation
      ? MediaDevice(DevicePlatform.android, backend.id, adbPath: backend.adbPath)
      : MediaDevice(DevicePlatform.ios, backend.id);

  /// The app's location permission, which only the simulator and the emulator let glint read.
  Future<String?> _access(LocationBackend backend, String? app) async =>
      app == null || backend is IosDeviceLocation ? null : readLocationAccess(_mediaDevice(backend), app);

  Future<(List<String>, Map<String, Object?>)> _signals(LocationBackend backend, String? app) async {
    final s = await backend.signals(app);
    final access = await _access(backend, app);
    final warnings = [
      if (s.servicesOn == false) 'location services are off on ${backend.label}: apps get no position at all',
      if (access == 'denied') '$app is denied location: it sees no fix; `location op:permission value:whileUsing`, or answer its prompt',
      if (access == 'notAsked') '$app has not been asked for location yet: it sees no fix until it asks and gets an answer (`location op:answer`)',
      if (s.listening == false && access != 'denied' && access != 'notAsked')
        '$app has no live location request yet: it shows the fix once it asks (is the screen that tracks location open?)',
    ];
    return (
      warnings,
      {if (access != null) 'permission': access, if (s.servicesOn != null) 'servicesOn': s.servicesOn, if (s.listening != null) 'appListening': s.listening},
    );
  }

  Future<StructuredResponse> _permission(LocationBackend backend, Map<String, Object?> args, String? app) async {
    final value = args['value'] as String?;
    if (!locationAccessValues.contains(value)) return _bad('permission needs value: ${locationAccessValues.join(' | ')}; got ${value ?? 'nothing'}');
    if (backend is IosDeviceLocation) {
      return StructuredResponse.error(
        summary: 'glint cannot set app permissions on a physical iPhone',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'devicectl has no privacy setting; only the person holding the phone can answer or change it in Settings',
        nextSteps: const ['ask the user to answer the prompt, or change it in Settings > Privacy & Security > Location Services'],
      );
    }
    final appId = (args['appId'] as String?) ?? app;
    if (appId == null) return _bad('no app to set location permission for', nextSteps: const ['attach the app, or pass appId:"<bundle id or package>"']);
    final before = await _access(backend, appId);
    final done = await setLocationAccess(_mediaDevice(backend), appId, value!);
    final now = await _access(backend, appId);
    return StructuredResponse(
      summary: '$appId location permission on ${backend.label}: ${before ?? 'unknown'} -> ${now ?? value}',
      warnings: [if (done.caution != null) done.caution!],
      nextSteps: [
        if (value == 'reset') 'make the app ask again (its own button, or `hot_reload restart:true`), then `location op:answer`',
        if (value != 'reset') 'get_scene to see how the app reacts',
      ],
      data: {'device': backend.id, 'appId': appId, 'before': before, 'permission': now, 'applied': done.applied},
    );
  }

  Future<StructuredResponse> _services(LocationBackend backend, Map<String, Object?> args) async {
    final value = args['value'] as String?;
    if (value != 'on' && value != 'off') return _bad('services needs value: on | off; got ${value ?? 'nothing'}');
    if (backend is! AndroidEmulatorLocation) {
      return StructuredResponse.error(
        summary: 'glint can switch location services on an Android emulator only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'iOS keeps that switch in Settings, out of reach of simctl and devicectl',
        nextSteps: const ['to test "no location" on iOS, `location op:permission value:deny`'],
      );
    }
    final ok = await setAndroidLocationServices(_mediaDevice(backend), value == 'on');
    if (!ok) {
      return StructuredResponse.error(
        summary: 'location services on ${backend.label} did not turn $value',
        errorKind: GlintErrorKind.backendToolError,
        nextSteps: const ['check the emulator is running (adb devices), then retry'],
      );
    }
    return StructuredResponse(
      summary: '${backend.label}: location services are now $value',
      warnings: [
        if (value == 'off') 'Google Play services may put a "turn on location" dialog over the app the next time it asks; get_scene shows it',
      ],
      nextSteps: const ['get_scene to see how the app reacts'],
      data: {'device': backend.id, 'servicesOn': value == 'on'},
    );
  }

  Future<StructuredResponse> _answer(GlintSession session, LocationBackend backend, Map<String, Object?> args, String? app) async {
    final choice = args['choice'] as String?;
    if (!locationAnswers.containsKey(choice)) return _bad('answer needs choice: ${locationAnswers.keys.join(' | ')}; got ${choice ?? 'nothing'}');
    final active = session.isAttached && session.device.id == backend.id ? session.active : null;
    final reader = session.nativeReader;
    if (active == null || reader == null) {
      return StructuredResponse.error(
        summary: 'attach the app first: answer reads the system prompt over it',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['attach (the app in Flutter mode)'],
      );
    }
    if (session.device is IosSimulator && reader is! RunnerNativeReader) {
      return StructuredResponse.error(
        summary: 'glint cannot read the iOS location prompt on this attach',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'the prompt belongs to the system, and only the XCUITest runner can read it',
        nextSteps: const ['attach iosBackend:"xctest", then answer', 'or set it without a prompt: `location op:permission`'],
      );
    }
    await active.refreshSceneMode();
    final surface = active.nativeSurfaceName;
    final prompt = surface == null ? null : LocationPrompt.find((await reader.readSnapshot()).root.children);
    if (prompt == null) {
      return StructuredResponse.error(
        summary: surface == null ? 'no system prompt is open' : '$surface is open, but it is not a location prompt',
        errorKind: GlintErrorKind.targetNotFound,
        nextSteps: [
          if (surface == null) 'make the app ask for location (its own button, or `hot_reload restart:true`), then answer',
          if (surface != null) 'get_scene to see it and answer it with tap',
          'or set it without a prompt: `location op:permission`',
        ],
      );
    }
    final button = prompt.answers[choice];
    if (button == null) {
      return StructuredResponse.error(
        summary: 'the prompt offers no "$choice"',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'it asks "${prompt.title}" and offers: ${prompt.answers.entries.map((e) => '${e.key} ("${e.value.label}")').join(', ')}',
        nextSteps: [for (final k in prompt.answers.keys) 'choice:"$k"'],
      );
    }
    final dpr = session.device.devicePixelRatio;
    Future<void> tap(PromptButton b) => session.backend.tap(physicalX: (b.x * dpr).round(), physicalY: (b.y * dpr).round());
    final precise = argBool(args, 'precise');
    final warnings = <String>[];
    if (precise != null) {
      final accuracy = prompt.precision[precise];
      if (accuracy == null) {
        warnings.add('this prompt has no precise or approximate choice, so precise:$precise was not applied');
      } else {
        await tap(accuracy);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    await tap(button);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await active.refreshSceneMode();
    final closed = active.nativeSurfaceName == null;
    final now = await _access(backend, app);
    return StructuredResponse(
      summary: 'answered "${button.label}"${precise == null || prompt.precision.isEmpty ? '' : ' (${precise ? 'precise' : 'approximate'})'}'
          '${closed ? '; the prompt closed' : '; a system surface is still open'}${now == null ? '' : '; $app permission: $now'}',
      warnings: [...warnings, if (!closed) 'something is still over the app: a follow-up prompt, or the tap missed'],
      nextSteps: [closed ? 'get_scene to see how the app reacts' : 'get_scene to see what is open'],
      data: {'device': backend.id, 'answered': button.label, 'promptClosed': closed, if (now != null) 'permission': now},
    );
  }

  Future<StructuredResponse> _set(LocationBackend backend, Map<String, Object?> args, String? app) async {
    final at = _parsePoint(args['at']);
    if (at == null) return _bad('set needs at:"lat,lng" in degrees, got ${args['at'] ?? 'nothing'}', nextSteps: const ['e.g. at:"6.5244,3.3792"']);
    final speed = argNum(args, 'speedKmh');
    final fix = (at: at, speed: speed == null ? null : speed / 3.6, heading: argNum(args, 'heading'), altitude: null);
    final registry = LocationRegistry.instance;
    final wasRouting = registry.player(backend.id)?.active ?? false;
    registry.stopRoute(backend.id);
    await backend.set(fix);
    registry.setFix(backend.id, fix);
    final (warnings, signals) = await _signals(backend, app);
    return StructuredResponse(
      summary: '${backend.label} is now at ${_fmt(at)}${wasRouting ? ' (stopped the route that was playing)' : ''}',
      warnings: warnings,
      nextSteps: const ['get_scene to see how the app shows it'],
      data: {'device': backend.id, ..._fixData(fix), ...signals},
    );
  }

  Future<StructuredResponse> _get(LocationBackend backend, String? app) async {
    final registry = LocationRegistry.instance;
    final player = registry.player(backend.id);
    final fix = registry.lastFix(backend.id);
    final (warnings, signals) = await _signals(backend, app);
    if (player == null) {
      return StructuredResponse(
        summary: fix == null
            ? 'glint has not set a location on ${backend.label} since it started'
            : '${backend.label} is at ${_fmt(fix.at)}, set by glint',
        warnings: warnings,
        nextSteps: [if (fix == null) '`location op:set at:"lat,lng"` or op:route to start'],
        data: {'device': backend.id, if (fix != null) ..._fixData(fix), ...signals},
      );
    }
    return StructuredResponse(
      summary: _routeLine(backend, player),
      warnings: [
        ...warnings,
        if (player.state == RouteState.failed) 'the route stopped after 3 failed fixes: ${player.lastError}',
        if (player.lastError != null && player.state != RouteState.failed) 'a fix failed: ${player.lastError}',
      ],
      nextSteps: _routeSteps(player),
      data: {'device': backend.id, ..._routeData(player), ...signals},
    );
  }

  String _routeLine(LocationBackend backend, LocationPlayer p) {
    final pct = (p.fraction * 100).round();
    final where = p.lastFix == null ? '' : ' at ${_fmt(p.lastFix!.at)}';
    return switch (p.state) {
      RouteState.playing => 'route $pct% done on ${backend.label}$where, ${_km(p.path.lengthMeters - p.meters)} and about ${_dur(p.remaining)} to go${p.laps > 0 ? ', lap ${p.laps + 1}' : ''}',
      RouteState.paused => 'route paused at $pct% on ${backend.label}$where',
      RouteState.finished => 'route finished on ${backend.label}$where',
      RouteState.stopped => 'route stopped at $pct% on ${backend.label}$where',
      RouteState.failed => 'route failed at $pct% on ${backend.label}$where',
    };
  }

  List<String> _routeSteps(LocationPlayer p) => switch (p.state) {
        RouteState.playing => const ['keep using the app; the position moves on its own', '`location op:pause`, op:seek progress:0.9, or op:stop'],
        RouteState.paused => const ['`location op:resume` carries on from here', 'op:seek moves without travelling'],
        _ => const ['`location op:route` starts a new route', 'op:seek progress:0 replays this one paused'],
      };

  Map<String, Object?> _routeData(LocationPlayer p) => {
        'state': p.state.name,
        'progress': double.parse(p.fraction.toStringAsFixed(3)),
        'meters': p.meters.round(),
        'lengthMeters': p.path.lengthMeters.round(),
        'waypoint': p.waypoint,
        'waypoints': p.path.points.length,
        'remainingSec': p.remaining.inSeconds,
        'speedKmh': double.parse((p.spec.speed * 3.6).toStringAsFixed(1)),
        'intervalMs': p.spec.interval.inMilliseconds,
        if (p.spec.loop) 'laps': p.laps,
        'travel': p.native ? 'device' : 'perFix',
        if (!p.native) 'fixesSent': p.sent,
        if (p.dropped > 0) 'fixesDropped': p.dropped,
        if (p.late > 0) 'fixesLate': p.late,
        if (p.lastFix != null) 'last': _fixData(p.lastFix!),
        if (p.lastError != null) 'lastError': p.lastError,
      };

  Future<StructuredResponse> _clear(LocationBackend backend) async {
    final registry = LocationRegistry.instance;
    final stopped = registry.stopRoute(backend.id);
    final cleared = await backend.clear();
    registry.forget(backend.id);
    final routeNote = stopped == null ? '' : ' and stopped the route';
    if (!cleared) {
      return StructuredResponse(
        summary: '${backend.label} keeps reporting its last position$routeNote: an emulator has no "no location" state',
        nextSteps: const ['to test "no location", turn location off or deny the app\'s location permission on the device'],
        data: {'device': backend.id, 'cleared': false},
      );
    }
    return StructuredResponse(
      summary: 'cleared the simulated location on ${backend.label}$routeNote',
      nextSteps: const ['get_scene to see how the app handles losing it'],
      data: {'device': backend.id, 'cleared': true},
    );
  }

  Future<StructuredResponse> _route(LocationBackend backend, Map<String, Object?> args, String? app) async {
    final sources = [args['points'], args['file'], args['polyline']].where((v) => v != null).length;
    if (sources != 1) return _bad('route needs exactly one of points, file or polyline', nextSteps: const ['e.g. points:["6.5244,3.3792","6.4281,3.4219"]']);
    final List<LatLng> points;
    final String from;
    if (args['points'] case final List raw) {
      final parsed = raw.map(_parsePoint).toList();
      final badAt = parsed.indexOf(null);
      if (badAt >= 0) return _bad('points[$badAt] is not "lat,lng" in degrees: ${raw[badAt]}');
      points = parsed.cast<LatLng>();
      from = '${points.length} points';
    } else if (args['file'] case final String path) {
      final file = File(path);
      if (!file.existsSync()) return _bad('route file not found: $path', nextSteps: const ['pass an absolute host path to a .gpx or .kml file']);
      final text = file.readAsStringSync();
      final kml = path.toLowerCase().endsWith('.kml') || text.contains('<kml');
      points = kml ? parseKml(text) : parseGpx(text);
      from = file.uri.pathSegments.last;
    } else {
      try {
        points = decodePolyline(args['polyline'] as String);
      } on Object {
        return _bad('polyline is not a valid encoded polyline');
      }
      from = 'the polyline';
    }
    if (points.length < 2) return _bad('a route needs at least 2 points, got ${points.length}${args['points'] == null ? ' from $from' : ''}');
    final path = GeoPath(points);
    if (path.lengthMeters < 1) return _bad('the route has no length: all its points are the same place', nextSteps: const ['use `location op:set` for one position']);

    final durationSec = argNum(args, 'durationSec');
    final speedKmh = argNum(args, 'speedKmh') ?? 30;
    if (durationSec != null && durationSec <= 0) return _bad('durationSec must be above 0');
    if (durationSec == null && (speedKmh <= 0 || speedKmh > 1200)) return _bad('speedKmh must be above 0 and at most 1200, got $speedKmh');
    final speed = durationSec != null ? path.lengthMeters / durationSec : speedKmh / 3.6;
    final askedMs = argInt(args, 'intervalMs') ?? 1000;
    final intervalMs = askedMs < backend.minInterval.inMilliseconds ? backend.minInterval.inMilliseconds : askedMs;
    final jitterM = argNum(args, 'jitterM') ?? 0;
    final dropout = argNum(args, 'dropout') ?? 0;
    if (jitterM < 0 || jitterM > 500) return _bad('jitterM must be 0 to 500');
    if (dropout < 0 || dropout >= 1) return _bad('dropout must be 0 or more and below 1');
    final progress = argNum(args, 'progress') ?? 0;
    if (progress < 0 || progress > 1) return _bad('progress must be 0 to 1');

    final spec = RouteSpec(
      speed: speed,
      interval: Duration(milliseconds: intervalMs),
      loop: argBool(args, 'loop') ?? false,
      jitterMeters: jitterM,
      dropout: dropout,
    );
    final player = LocationPlayer(backend, path, spec)..meters = path.lengthMeters * progress;
    LocationRegistry.instance.play(backend.id, player);
    await player.start();
    if (player.state == RouteState.failed) throw LocationFailed('the device refused the first fix', player.lastError ?? '');
    final (warnings, signals) = await _signals(backend, app);
    final noise = [if (jitterM > 0) '${jitterM.round()} m noise', if (dropout > 0) '${(dropout * 100).round()}% fixes lost'];
    return StructuredResponse(
      summary: 'playing a ${_km(path.lengthMeters)} route from $from on ${backend.label} at ${(speed * 3.6).toStringAsFixed(speed * 3.6 < 10 ? 1 : 0)} km/h, '
          'one fix every ${(intervalMs / 1000).toStringAsFixed(intervalMs % 1000 == 0 ? 0 : 1)} s${noise.isEmpty ? '' : ' (${noise.join(', ')})'}: '
          '${spec.loop ? 'looping' : 'about ${_dur(player.remaining)} to the end'}',
      warnings: [
        ...warnings,
        if (speed * 3.6 > 1000) 'faster than a plane: Android\'s fused location drops fixes that imply this speed, so the app may not move; use durationSec for a longer time',
        if (askedMs < intervalMs) 'intervalMs raised to $intervalMs: ${backend.label} takes no fixes faster',
        if (backend is IosDeviceLocation) 'an iPhone takes position only: the app sees no speed or heading',
        if (backend is IosSimulatorLocation && !player.native) 'with jitterM or dropout the simulator gets one fix at a time, so the app sees no heading',
        if (backend is IosSimulatorLocation) 'iOS reports speed 0 for simulated travel; apps that show speed must work it out from successive fixes',
      ],
      nextSteps: const ['keep using the app; the position moves in the background', '`location op:get` for progress; pause, resume, seek or stop any time'],
      data: {'device': backend.id, ..._routeData(player), ...signals},
    );
  }

  StructuredResponse _noRoute(LocationBackend backend) => StructuredResponse.error(
        summary: 'no route is playing on ${backend.label}',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['`location op:route` starts one'],
      );

  Future<StructuredResponse> _control(LocationBackend backend, String op) async {
    final player = LocationRegistry.instance.player(backend.id);
    if (player == null) return _noRoute(backend);
    final before = player.state;
    await switch (op) {
      'pause' => player.pause(),
      'resume' => player.resume(),
      _ => player.halt(),
    };
    final unchanged = player.state == before;
    return StructuredResponse(
      summary: unchanged ? 'nothing to $op: ${_routeLine(backend, player)}' : _routeLine(backend, player),
      nextSteps: _routeSteps(player),
      data: {'device': backend.id, ..._routeData(player)},
    );
  }

  Future<StructuredResponse> _seek(LocationBackend backend, Map<String, Object?> args) async {
    final player = LocationRegistry.instance.player(backend.id);
    if (player == null) return _noRoute(backend);
    if (player.state == RouteState.stopped || player.state == RouteState.failed) {
      return _bad('the route on ${backend.label} is ${player.state.name}', nextSteps: const ['`location op:route` starts it again']);
    }
    final progress = argNum(args, 'progress');
    final meters = argNum(args, 'meters');
    final waypoint = argInt(args, 'waypoint');
    if ([progress, meters, waypoint].where((v) => v != null).length != 1) return _bad('seek needs exactly one of progress, meters or waypoint');
    if (progress != null && (progress < 0 || progress > 1)) return _bad('progress must be 0 to 1');
    if (waypoint != null && (waypoint < 0 || waypoint >= player.path.points.length)) {
      return _bad('waypoint must be 0 to ${player.path.points.length - 1}');
    }
    final to = progress != null ? progress * player.path.lengthMeters : (meters ?? player.path.metersAtWaypoint(waypoint!));
    await player.seek(to);
    return StructuredResponse(
      summary: 'moved to ${_km(player.meters)} along the route: ${_routeLine(backend, player)}',
      warnings: [if (player.lastError != null) 'a fix failed: ${player.lastError}'],
      nextSteps: _routeSteps(player),
      data: {'device': backend.id, ..._routeData(player)},
    );
  }
}
