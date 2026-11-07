import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../interaction/result.dart';
import '../interaction/siminject.dart';
import 'host_tools.dart';

const _moduleName = 'calls';

bool _flag(Object? v) => v == true || v == 1;

/// The call kinds the iOS simulator takes: they change what apps see through AVAudioSession and CallKit.
const simCallKinds = {'call', 'answerCall', 'declineCall', 'endCall', 'callkit'};

/// One call an app holds, as the injected library reports it.
typedef SimCall = ({String uuid, String kind, String name, String state, bool onHold});

/// What the injected library in one app reports about calls right now.
class CallsApp {
  const CallsApp({
    required this.pid,
    required this.bundleId,
    required this.epoch,
    required this.ack,
    required this.foreground,
    required this.callkitLinked,
    required this.observerPath,
    required this.calls,
    required this.observers,
    required this.providers,
    required this.interruption,
    required this.overlay,
    required this.journal,
  });

  final int pid;
  final String bundleId;

  /// The enable cycle this report belongs to; a report from another one is stale.
  final String epoch;

  /// The last command sequence number the app applied in [epoch].
  final int ack;

  /// Whether the app was in the foreground when it last reported.
  final bool foreground;

  /// Whether the app has CallKit loaded, so it can have observers and providers at all.
  final bool callkitLinked;

  /// `ok`, or `unavailable` when this iOS has no CXCall API glint can use to tell observers.
  final String observerPath;
  final List<SimCall> calls;

  /// `CXCallObserver` instances with a delegate the app created.
  final int observers;

  /// `CXProvider` instances the app created.
  final int providers;

  /// The last `AVAudioSession` interruption posted: none, began or ended.
  final String interruption;

  /// Whether the Answer/Decline or End call overlay is on screen in this app.
  final bool overlay;
  final List<String> journal;

  /// Whether a call of [kind] is in [state] here.
  bool has(String kind, String state) => calls.any((c) => c.kind == kind && c.state == state);

  Map<String, Object?> toJson() => {
        'bundleId': bundleId,
        'calls': [
          for (final c in calls) {'kind': c.kind, 'name': c.name, 'state': c.state, if (c.onHold) 'onHold': true},
        ],
        'callkitLinked': callkitLinked,
        'observerPath': observerPath,
        'callObservers': observers,
        'callkitProviders': providers,
        'interruption': interruption,
        'overlay': overlay,
      };
}

/// What a command did: the apps that applied it, the loaded apps that did not (named, never waited for), whether the expected state held in the app that had to take it, and that app's last report.
typedef CallsOutcome = ({List<CallsApp> apps, List<String> silent, bool held, List<CallsApp> required});

/// An incoming cellular call and CallKit stand-in for an iOS simulator, through the injected library's `calls` module.
class SimCalls {
  SimCalls(this.injector);

  final SimInjector injector;

  /// Whether the module is on.
  bool get on => injector.moduleConfig(_moduleName) != null;

  Map<String, Object?> get _config => injector.moduleConfig(_moduleName) ?? const {};

  String get _epoch => (_config['epoch'] as String?) ?? '';

  int get _seq => (_config['seq'] as num?)?.toInt() ?? 0;

  /// The apps holding the library that report calls state.
  List<CallsApp> apps({Set<int>? alive}) {
    alive ??= {for (final a in injector.loaded()) a.pid};
    final dir = Directory('${injector.controlDir}/events');
    if (!dir.existsSync()) return const [];
    final apps = <CallsApp>[];
    for (final f in dir.listSync().whereType<File>().where((f) => RegExp(r'calls-\d+\.json$').hasMatch(f.path))) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        final pid = j['pid'] as int;
        if (!alive.contains(pid)) {
          f.deleteSync();
          continue;
        }
        apps.add(
          CallsApp(
            pid: pid,
            bundleId: (j['bundleId'] as String?) ?? '',
            epoch: (j['epoch'] as String?) ?? '',
            ack: (j['ack'] as num?)?.toInt() ?? 0,
            foreground: _flag(j['foreground']),
            callkitLinked: _flag(j['callkitLinked']),
            observerPath: (j['observerPath'] as String?) ?? 'ok',
            calls: [
              for (final c in (j['calls'] as List? ?? const []).cast<Map<String, Object?>>())
                (
                  uuid: '${c['uuid']}',
                  kind: '${c['kind']}',
                  name: '${c['name']}',
                  state: '${c['state']}',
                  onHold: _flag(c['onHold']),
                ),
            ],
            observers: (j['observers'] as num?)?.toInt() ?? 0,
            providers: (j['providers'] as num?)?.toInt() ?? 0,
            interruption: (j['interruption'] as String?) ?? 'none',
            overlay: _flag(j['overlay']),
            journal: ((j['journal'] as List?) ?? const []).cast<String>(),
          ),
        );
      } on Object {
        continue;
      }
    }
    return apps;
  }

  /// Turns the module on with no call and a new epoch, so apps' own CallKit calls get the stand-in UI and no earlier command can replay.
  Future<void> enable() async {
    if (on) return;
    final epoch =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 32).toRadixString(36)}';
    await injector.setModule(_moduleName, {'epoch': epoch, 'seq': 0});
  }

  bool _took(CallsApp a, int seq) => a.epoch == _epoch && a.ack >= seq;

  /// The apps that must take a command: [primary] (the attached app) when it holds the library, else every app in front.
  List<CallsApp> _required(List<CallsApp> all, String? primary) {
    final current = all.where((a) => a.epoch == _epoch).toList();
    final named = current.where((a) => primary != null && a.bundleId == primary).toList();
    return named.isNotEmpty ? named : current.where((a) => a.foreground).toList();
  }

  CallsOutcome _outcome(List<CallsApp> all, int seq, {String? primary, bool held = true}) => (
        apps: all.where((a) => _took(a, seq)).toList(),
        silent: [
          for (final a in all)
            if (!_took(a, seq)) a.bundleId
        ],
        held: held,
        required: _required(all, primary),
      );

  /// Waits until the app in front has reported in this epoch (any app when none is in front, up to a bound), and says who did not.
  Future<CallsOutcome> reported({String? primary, PhaseReporter? phases}) async {
    Future<CallsOutcome> wait() async {
      final started = DateTime.now();
      var now = apps();
      while (DateTime.now().difference(started) < const Duration(seconds: 6)) {
        final fresh = now.where((a) => a.epoch == _epoch);
        if (_required(now, primary).isNotEmpty ||
            (fresh.isNotEmpty && DateTime.now().difference(started) > const Duration(seconds: 3))) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        now = apps();
      }
      return _outcome(now, 0, primary: primary);
    }

    return phases?.during('waiting for the app to report its calls', wait) ?? wait();
  }

  /// Sends [verb] (ring, answer, decline or end) and waits for the app in front ([primary] when it holds the library) to apply it, then up to 5 s for [until] over that app's report (`held`); the command stays in the config, so an app that loads or resumes before the next command takes it once.
  Future<CallsOutcome> send(
    String verb, {
    String? number,
    String? name,
    String? primary,
    PhaseReporter? phases,
    bool Function(List<CallsApp>)? until,
    bool Function(List<CallsApp>)? settle,
  }) async {
    await enable();
    final epoch = _epoch;
    final seq = _seq + 1;
    await injector.setModule(_moduleName, {
      'epoch': epoch,
      'seq': seq,
      'command': {'seq': seq, 'do': verb, if (number != null) 'number': number, if (name != null) 'name': name},
    });
    Future<List<CallsApp>> wait() async {
      final started = DateTime.now();
      while (DateTime.now().difference(started) < const Duration(seconds: 10)) {
        final now = apps();
        final required = _required(now, primary);
        if (required.isNotEmpty && required.every((a) => _took(a, seq))) return now;
        final reportedAny = now.any((a) => a.epoch == _epoch);
        if (required.isEmpty &&
            (reportedAny || primary == null) &&
            DateTime.now().difference(started) > const Duration(seconds: 4)) {
          throw SimInjectFailure(
            GlintErrorKind.appNotResumed,
            'no app is in the foreground to take the call',
            'apps holding the library: ${now.map((a) => a.bundleId).join(', ')}; none is active',
            ['bring the app to the foreground (attach, or open it), then repeat the call'],
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final now = apps();
      final required = _required(now, primary);
      final background = required.isNotEmpty && required.every((a) => !a.foreground);
      throw SimInjectFailure(
        background ? GlintErrorKind.appNotResumed : GlintErrorKind.appUnresponsive,
        background
            ? '${required.map((a) => a.bundleId).join(', ')} is not in the foreground to take the call'
            : 'the foreground app did not apply the call command within 10 s',
        'apps holding the library: ${now.map((a) => a.bundleId).join(', ')}',
        [
          background
              ? 'bring the app to the foreground, then repeat the call'
              : 'check the app is not frozen (get_scene), then repeat the call',
          '`media op:event kind:"callkit" stop:true` then `kind:"call"` loads glint again',
        ],
      );
    }

    var now = await (phases?.during('waiting for the app to take the $verb', wait) ?? wait());
    var held = true;
    if (until != null) {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      held = until(_required(now, primary).where((a) => _took(a, seq)).toList());
      while (!held && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        now = apps();
        held = until(_required(now, primary).where((a) => _took(a, seq)).toList());
      }
    }
    if (settle != null) {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!settle(_required(now, primary)) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        now = apps();
      }
    }
    return _outcome(now, seq, primary: primary, held: held);
  }

  /// Turns the module off and removes what glint left for it; true when it was on.
  Future<bool> stop() async {
    final was = on;
    await injector.setModule(_moduleName, null);
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    final alive = {for (final a in injector.loaded()) a.pid};
    while (DateTime.now().isBefore(deadline) && apps(alive: alive).any((a) => a.foreground)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final events = Directory('${injector.controlDir}/events');
    if (events.existsSync()) {
      for (final f in events.listSync().whereType<File>().where((f) => f.path.contains('/calls-'))) {
        f.deleteSync();
      }
    }
    for (final name in const ['events', 'modules']) {
      final dir = Directory('${injector.controlDir}/$name');
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    }
    if (injector.activeModules().isEmpty) await injector.clearLaunchEnv();
    return was;
  }
}
