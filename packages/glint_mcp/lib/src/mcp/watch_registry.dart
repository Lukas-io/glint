import 'dart:async';

import '../../observability.dart';
import '../media/host_tools.dart' show PhaseReporter;
import 'session.dart';
import 'watch_conditions.dart';
import 'watch_events.dart';
import 'watch_observation.dart';

/// One registered watch: conditions on one app, or alert conditions on every attached app, any of which fires it.
class Watch {
  Watch({
    required this.id,
    required this.label,
    required this.app,
    required this.conditions,
    required this.once,
    required this.timeoutMs,
  }) : createdAt = DateTime.now();

  final String id;
  final String? label;

  /// The app watched; null for a watch over every attached app, which takes alert conditions only.
  final AppSession? app;
  final List<ArmedCondition> conditions;
  final bool once;
  final int timeoutMs;
  final DateTime createdAt;
  Timer? deadline;
  bool ended = false;
  int matches = 0;

  bool get allApps => app == null;

  /// What the watch watches, for replies and events.
  String get target => app?.label ?? 'all apps';

  DateTime get expiresAt => createdAt.add(Duration(milliseconds: timeoutMs));

  bool get needsScene => conditions.any((c) => c.readsScene);
}

/// What `watch op:add` registered, and what already fired while it was being armed.
class WatchAdded {
  WatchAdded(this.watch, this.firedNow, this.observation, this.readNote, [this.alertNotes = const []]);

  final Watch watch;
  final List<Map<String, Object?>> firedNow;
  final WatchObservation? observation;

  /// Why the first read of the app failed, when it did; the watch keeps trying.
  final String? readNote;

  /// Alert sources that cannot be read, such as HTTP profiling of one app.
  final List<String> alertNotes;
}

/// The watches of one glint session: evaluates them in the background and writes each event to [events].
class WatchRegistry {
  WatchRegistry(this._session, {String? dir, int? ownPid})
      : events = WatchEventLog(dir: dir ?? '${resolveDataDir()}/watch', ownPid: ownPid);

  static const maxWatches = 20;
  static const maxEventsPerWatch = 200;
  static const defaultTimeoutMs = 30 * 60 * 1000;
  static const maxTimeoutMs = 6 * 60 * 60 * 1000;
  static const _logGap = Duration(seconds: 1);
  static const _baselineLimit = Duration(seconds: 6);

  final GlintSession _session;
  final WatchEventLog events;
  final Map<String, Watch> _watches = {};
  final Map<AppSession, _Poller> _pollers = {};
  int _nextId = 1;

  /// Forwards each event to the client as a logging notification; wired by the server.
  void Function(Map<String, Object?> event)? notifier;

  List<Watch> get active => _watches.values.toList();

  Watch? byId(String id) => _watches[id];

  /// Time between scene reads while the app answers.
  Duration get tick => const Duration(milliseconds: 1500);

  /// Why watches on [app] are not being read right now, null when they are.
  String? holdReason(AppSession app) => _pollers[app]?.holdReason;

  /// The route the last scene read of [app] showed.
  String? routeOf(AppSession app) => _pollers[app]?.last?.route;

  /// Registers a watch on [app], or on every attached app and every app attached later when [app] is null (alert conditions only).
  Future<WatchAdded> add(
    AppSession? app, {
    required List<WatchCondition> conditions,
    required String? label,
    required bool once,
    required int timeoutMs,
    void Function(int elapsedSec, String phase)? progress,
  }) async {
    events.open();
    final watch = Watch(
      id: 'w${_nextId++}',
      label: label,
      app: app,
      conditions: [for (final c in conditions) ArmedCondition(c)],
      once: once,
      timeoutMs: timeoutMs,
    );
    _watches[watch.id] = watch;
    watch.deadline = Timer(Duration(milliseconds: timeoutMs), () {
      end(watch, 'timeout', detail: 'nothing matched within ${_span(Duration(milliseconds: timeoutMs))}');
    });
    final pending = <Future<String?>>[];
    var waitsOnHttp = false;
    for (final c in watch.conditions) {
      if (c.spec is LogCondition) {
        c.logSubscription = app!.appLogs.onEntry.listen((entry) => _onLog(watch, c, entry));
      }
      if (c.spec case AlertsCondition(:final wantsHttp)) {
        waitsOnHttp = waitsOnHttp || wantsHttp;
        final targets = app != null ? [app] : _alertable(_session.apps);
        for (final target in targets) {
          pending.add(_listen(watch, c, target));
        }
      }
    }
    final settled = waitsOnHttp
        ? await PhaseReporter(progress)
            .during('starting HTTP profiling on ${pending.length} app(s)', () => Future.wait(pending))
        : await Future.wait(pending);
    final notes = [
      for (final note in settled)
        if (note != null) note,
    ];
    final fromSeq = events.lastSeq;
    String? note;
    WatchObservation? seen;
    if (watch.needsScene) {
      final poller = _pollers.putIfAbsent(app!, () => _Poller(this, app));
      await poller.readNow().timeout(_baselineLimit, onTimeout: () {});
      note = poller.holdReason;
      seen = poller.last;
    }
    return WatchAdded(watch, events.since(fromSeq, watch: watch.id), seen, note, notes);
  }

  static List<AppSession> _alertable(Iterable<AppSession> apps) => [
        for (final a in apps)
          if (!a.deviceMode) a,
      ];

  Future<String?> _listen(Watch watch, ArmedCondition condition, AppSession app) async {
    final spec = condition.spec as AlertsCondition;
    if (condition.alertSubscriptions.containsKey(app)) return null;
    condition.alertSubscriptions[app] = app.alerts.listen((alert) => _onAlert(watch, condition, app, alert));
    if (!spec.wantsHttp) return null;
    condition.httpHeld.add(app);
    final note = await app.httpFailures.acquire();
    return note == null ? null : 'http alerts for ${app.label} are unavailable: $note';
  }

  void _unlisten(ArmedCondition condition, AppSession app) {
    condition.alertSubscriptions.remove(app)?.cancel();
    if (condition.httpHeld.remove(app)) app.httpFailures.release();
  }

  /// Starts every all-apps alert watch on [app], which was just attached.
  void appAttached(AppSession app) {
    if (app.deviceMode) return;
    for (final watch in _watches.values.toList()) {
      if (!watch.allApps || watch.ended) continue;
      for (final c in watch.conditions) {
        if (c.spec is! AlertsCondition) continue;
        unawaited(_listen(watch, c, app).then((note) {
          if (note != null && !watch.ended) {
            _emit({
              'watch': watch.id,
              if (watch.label != null) 'label': watch.label,
              'kind': 'note',
              'detail': note,
              'app': app.label,
              'device': app.id,
            });
          }
        }));
      }
    }
  }

  /// Ends [id]; false when no such watch is active.
  bool cancel(String id) {
    final watch = _watches[id];
    if (watch == null) return false;
    end(watch, 'cancelled', detail: 'cancelled by the agent');
    return true;
  }

  int cancelAll({AppSession? app}) {
    final targets = [
      for (final w in _watches.values)
        if (app == null || identical(w.app, app)) w,
    ];
    for (final w in targets) {
      end(w, 'cancelled', detail: 'cancelled by the agent');
    }
    return targets.length;
  }

  /// Ends every watch on [app], which was detached or replaced; all-apps watches just stop listening to it.
  void appDropped(AppSession app) {
    for (final w in _watches.values.toList()) {
      if (identical(w.app, app)) {
        end(w, 'detached', detail: '${app.label} was detached');
      } else if (w.allApps) {
        for (final c in w.conditions) {
          _unlisten(c, app);
        }
      }
    }
  }

  /// Ends everything and removes the events file when it is empty; called as glint exits.
  void close() {
    for (final w in _watches.values.toList()) {
      end(w, 'shutdown', detail: 'glint is shutting down');
    }
    for (final p in _pollers.values) {
      p.stop();
    }
    _pollers.clear();
    events.close();
  }

  void end(Watch watch, String reason, {String? detail, bool announce = true}) {
    if (watch.ended) return;
    watch.ended = true;
    watch.deadline?.cancel();
    for (final c in watch.conditions) {
      c.logSubscription?.cancel();
      for (final app in c.alertSubscriptions.keys.toList()) {
        _unlisten(c, app);
      }
    }
    _watches.remove(watch.id);
    if (announce) {
      _emit({
        'watch': watch.id,
        if (watch.label != null) 'label': watch.label,
        'kind': 'ended',
        'reason': reason,
        if (detail != null) 'detail': detail,
        'matches': watch.matches,
        'app': watch.target,
        if (watch.app != null) 'device': watch.app!.id,
      });
    }
    if (watch.app != null) _retirePoller(watch.app!);
  }

  List<Watch> _sceneWatches(AppSession app) => [
        for (final w in _watches.values)
          if (identical(w.app, app) && w.needsScene) w,
      ];

  void _retirePoller(AppSession app) {
    if (_sceneWatches(app).isNotEmpty) return;
    _pollers.remove(app)?.stop();
  }

  void _fire(
    Watch watch,
    ArmedCondition condition,
    String matched, {
    AppSession? app,
    WatchObservation? before,
    WatchObservation? now,
    Map<String, Object?> extra = const {},
  }) {
    if (watch.ended) return;
    watch.matches++;
    final source = app ?? watch.app!;
    final appeared = now?.appearedSince(before);
    final route = now?.route ?? (watch.allApps ? null : routeOf(source));
    final last = watch.once || watch.matches >= maxEventsPerWatch;
    _emit({
      'watch': watch.id,
      if (watch.label != null) 'label': watch.label,
      'kind': 'match',
      'condition': condition.spec.describe,
      'matched': matched,
      if (route != null) 'route': route,
      'app': source.label,
      'device': source.id,
      ...extra,
      if (appeared != null && appeared.texts.isNotEmpty) 'appeared': appeared.texts,
      if (appeared != null && appeared.ids.isNotEmpty) 'appearedIds': appeared.ids,
      if (appeared != null && appeared.more > 0) 'appearedMore': appeared.more,
      if (last) 'final': true,
    });
    if (watch.once) {
      end(watch, 'matched', announce: false);
    } else if (watch.matches >= maxEventsPerWatch) {
      end(watch, 'eventLimit', detail: 'stopped after $maxEventsPerWatch events; add the watch again to keep going');
    }
  }

  void _onLog(Watch watch, ArmedCondition condition, AppLogEntry entry) {
    final spec = condition.spec as LogCondition;
    if (watch.ended || !entry.mentions(spec.pattern.hasMatch)) return;
    final now = DateTime.now();
    final lastHit = condition.lastLogHit;
    if (lastHit != null && now.difference(lastHit) < _logGap) {
      condition.suppressedLogHits++;
      return;
    }
    condition.lastLogHit = now;
    final suppressed = condition.suppressedLogHits;
    condition.suppressedLogHits = 0;
    _fire(watch, condition, _logLine(entry), extra: {if (suppressed > 0) 'suppressed': suppressed});
  }

  void _onAlert(Watch watch, ArmedCondition condition, AppSession app, AppAlert alert) {
    final spec = condition.spec as AlertsCondition;
    if (watch.ended || !spec.kinds.contains(alert.group)) return;
    _fire(watch, condition, alert.matched, app: app, extra: {'alert': alert.name, ...alert.fields});
  }

  void _evaluate(AppSession app, WatchObservation? before, WatchObservation now) {
    for (final w in _sceneWatches(app)) {
      for (final c in w.conditions) {
        if (w.ended) break;
        final hit = c.check(before, now);
        if (hit != null) _fire(w, c, hit.matched, before: before, now: now, extra: hit.extra);
      }
    }
  }

  void _emit(Map<String, Object?> fields) {
    final event = events.append(fields);
    try {
      notifier?.call(event);
    } on Object {
      // the file is the delivery channel; a failed notification loses nothing
    }
  }

  static String _logLine(AppLogEntry entry) {
    final first = entry.content.trimLeft().split('\n').first.trimRight();
    return first.length > 200 ? '${first.substring(0, 199)}…' : first;
  }

  static String _span(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h${d.inMinutes % 60 == 0 ? '' : ' ${d.inMinutes % 60} min'}';
    if (d.inMinutes >= 1) return '${d.inMinutes} min';
    return '${d.inSeconds} s';
  }

  /// How long is left before [watch] times out, for replies.
  static String timeLeft(Watch watch) {
    final left = watch.expiresAt.difference(DateTime.now());
    return left.isNegative ? '0 s' : _span(left);
  }

  /// [timeoutMs] as a short span, for replies.
  static String span(int timeoutMs) => _span(Duration(milliseconds: timeoutMs));
}

/// Reads one app's scene on a timer for every watch on it, backing off while the app cannot answer.
class _Poller {
  _Poller(this._registry, this.app) {
    _schedule();
  }

  static const _readLimit = Duration(seconds: 20);
  static const _maxDelay = Duration(seconds: 30);

  final WatchRegistry _registry;
  final AppSession app;
  Timer? _timer;
  Future<void>? _running;
  bool _stopped = false;
  int _failures = 0;
  WatchObservation? last;

  /// Why the last read did not happen or failed; null while reads work.
  String? holdReason;

  Duration get _delay {
    if (_failures == 0) return _registry.tick;
    final scaled = _registry.tick * (1 << (_failures > 5 ? 5 : _failures));
    return scaled > _maxDelay ? _maxDelay : scaled;
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  void _schedule() {
    _timer?.cancel();
    if (_stopped) return;
    _timer = Timer(_delay, readNow);
  }

  /// One read and evaluation now, after any read already running.
  Future<void> readNow() async {
    while (_running != null) {
      await _running;
    }
    if (_stopped) return;
    final run = _read().catchError((Object e) => _hold('$e'.split('\n').first));
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
    _schedule();
  }

  void _hold(String reason) {
    holdReason = reason;
    _failures++;
  }

  Future<void> _read() async {
    final watches = _registry._sceneWatches(app);
    if (watches.isEmpty) return;
    final texts = <String>{};
    final ids = <String>{};
    for (final w in watches) {
      for (final c in w.conditions) {
        if (c.spec case ShownCondition(:final text, :final glintId)) {
          if (text != null) texts.add(text);
          if (glintId != null) ids.add(glintId);
        }
      }
    }
    final now = await _observe(texts, ids);
    if (now == null || _stopped) return;
    final before = last;
    last = now;
    _registry._evaluate(app, before, now);
  }

  Future<WatchObservation?> _observe(Set<String> texts, Set<String> ids) async {
    if (!app.isLive) {
      _hold('the connection to ${app.label} is down');
      return null;
    }
    if (app.breakpoints.isPaused) {
      _hold('${app.label} is paused at a breakpoint');
      return null;
    }
    if (app.sceneMode == SceneMode.native) {
      final surface = app.nativeSurfaceName;
      if (surface == null) {
        _hold('${app.label} is in the background or the device is locked');
        return null;
      }
      holdReason = null;
      _failures = 0;
      return (last ?? WatchObservation()).withSurface(surface);
    }
    try {
      final session = _registry._session;
      final seen = await session
          .withApp(
            app,
            () => session.withScene(
              (scene) async => WatchObservation.read(scene, texts: texts, ids: ids),
              detail: SceneDetail.interactive,
            ),
          )
          .timeout(_readLimit);
      holdReason = null;
      _failures = 0;
      return seen;
    } on Object catch (e) {
      final text = '$e'.split('\n').first;
      _hold(text.length > 120 ? '${text.substring(0, 119)}…' : text);
      return null;
    }
  }
}
