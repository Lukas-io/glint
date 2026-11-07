import '../interaction/result.dart';
import '../interaction/siminject.dart';
import 'host_tools.dart';

const _moduleName = 'speech';

bool _flag(Object? v) => v == true || v == 1;

/// Failures a scripted `error` can name, with the error an app gets for each.
const simSpeechErrors = {
  'noSpeech': 'kAFAssistantErrorDomain 1110 (failed to recognize any speech)',
  'siriDisabled': 'kLSRErrorDomain 201 (Siri or Dictation is disabled)',
  'interrupted': 'kAFAssistantErrorDomain 1107 (connection to the speech process was interrupted)',
};

/// One recognition task of an app, finished or still live, as the injected library reports it.
typedef SpeechRun = ({
  int seq,
  String kind,
  int partials,
  int finals,
  String text,
  String failure,
  int buffers,
  bool live,
});

/// What the injected library in one app reports about speech recognition right now.
class SpeechApp {
  const SpeechApp({
    required this.bundleId,
    required this.epoch,
    required this.ack,
    required this.taken,
    required this.expired,
    required this.settled,
    required this.foreground,
    required this.speechLinked,
    required this.live,
    required this.history,
    required this.authRequests,
    required this.micRequests,
    required this.fakeEngineStarts,
    required this.realEngineStarts,
  });

  final String bundleId;

  /// The enable cycle this report belongs to; a report from another one is stale.
  final String epoch;

  /// The last command sequence number the app applied in [epoch].
  final int ack;

  /// The last command that reached at least one recognition task.
  final int taken;

  /// The last command that found no task listening within its wait.
  final int expired;

  /// The last command whose tasks have all ended, by a final result, an error or a cancel.
  final int settled;
  final bool foreground;

  /// Whether the app has the Speech framework loaded, so it can have recognition tasks at all.
  final bool speechLinked;
  final List<SpeechRun> live;
  final List<SpeechRun> history;

  /// Times the app asked for speech recognition permission and was told yes.
  final int authRequests;

  /// Times the app asked for microphone permission and was told yes.
  final int micRequests;

  /// Audio engine starts glint answered itself, so the real input was never opened.
  final int fakeEngineStarts;

  /// Audio engine starts handed to the real engine while the stand-in was on.
  final int realEngineStarts;

  /// What the tasks given command [seq] have received, finished and still running.
  List<SpeechRun> runsOf(int seq) => [
        for (final r in [...history, ...live])
          if (r.seq == seq) r
      ];
}

/// What a speech command did: the app that had to take it, whether it did, what it delivered and whether the stand-in was turned off meanwhile.
typedef SpeechOutcome = ({
  SpeechApp app,
  bool taken,
  bool settled,
  bool stopped,
  List<SpeechRun> runs,
  List<String> silent,
});

/// A scripted speaker for an iOS simulator, through the injected library's `speech` module: apps' `SFSpeechRecognizer` tasks get the results glint scripts.
class SimSpeech {
  SimSpeech(this.injector);

  final SimInjector injector;

  /// Whether the module is on.
  bool get on => injector.moduleConfig(_moduleName) != null;

  Map<String, Object?> get _config => injector.moduleConfig(_moduleName) ?? const {};

  String get _epoch => (_config['epoch'] as String?) ?? '';

  int get _seq => (_config['seq'] as num?)?.toInt() ?? 0;

  SpeechRun _run(Map<String, Object?> h, {required bool live}) => (
        seq: (h['seq'] as num?)?.toInt() ?? 0,
        kind: '${h['kind']}',
        partials: (h['partials'] as num?)?.toInt() ?? 0,
        finals: (h['finals'] as num?)?.toInt() ?? 0,
        text: '${h['text'] ?? ''}',
        failure: '${h['failure'] ?? ''}',
        buffers: (h['buffers'] as num?)?.toInt() ?? 0,
        live: live,
      );

  /// The apps among [alive] that report speech state.
  List<SpeechApp> apps(Set<int> alive) {
    int n(Map<String, Object?> j, String key) => (j[key] as num?)?.toInt() ?? 0;
    List<Map<String, Object?>> maps(Map<String, Object?> j, String key) =>
        [for (final m in (j[key] as List? ?? const [])) (m as Map).cast<String, Object?>()];
    return [
      for (final j in injector.readStatuses(_moduleName, alive: alive))
        SpeechApp(
          bundleId: (j['bundleId'] as String?) ?? '',
          epoch: (j['epoch'] as String?) ?? '',
          ack: n(j, 'ack'),
          taken: n(j, 'taken'),
          expired: n(j, 'expired'),
          settled: n(j, 'settled'),
          foreground: _flag(j['foreground']),
          speechLinked: _flag(j['speechLinked']),
          live: [for (final t in maps(j, 'tasks')) _run(t, live: true)],
          history: [for (final h in maps(j, 'history')) _run(h, live: false)],
          authRequests: n(j, 'authRequests'),
          micRequests: n(j, 'micRequests'),
          fakeEngineStarts: n(j, 'fakeEngineStarts'),
          realEngineStarts: n(j, 'realEngineStarts'),
        ),
    ];
  }

  /// Turns the module on with no command and a new epoch, so apps get authorization and availability from now on and no earlier command can replay.
  Future<void> enable() async {
    await injector.enableModule(_moduleName);
  }

  SpeechApp? _required(List<SpeechApp> all, String epoch, String? primary) {
    final current = all.where((a) => a.epoch == epoch).toList();
    for (final a in current) {
      if (primary != null && a.bundleId == primary) return a;
    }
    return current.where((a) => a.foreground).firstOrNull;
  }

  /// Sends [command] (`say` or `fail`) and waits for the app in front ([primary] when it holds the library) to hand it to a recognition task, then for the results to be delivered, up to [deliverySeconds] more. The command is removed from the config once taken or expired, so an app that loads later never replays it.
  Future<SpeechOutcome> send(
    Map<String, Object?> command, {
    String? primary,
    required int waitMs,
    required double deliverySeconds,
    PhaseReporter? phases,
  }) async {
    await enable();
    final epoch = _epoch;
    final seq = _seq + 1;
    var alive = injector.livePids();
    var files = injector.statusFiles(_moduleName);
    List<SpeechApp> read() {
      final now = injector.statusFiles(_moduleName);
      if (!files.containsAll(now)) alive = injector.livePids();
      files = now;
      return apps(alive);
    }

    await injector.setModule(_moduleName, {
      'epoch': epoch,
      'seq': seq,
      'command': {
        ...command,
        'seq': seq,
        'waitMs': waitMs,
        'sentAtMs': DateTime.now().millisecondsSinceEpoch,
        'target': primary ?? '',
      },
    });
    try {
      Future<SpeechApp> reach() async {
        final started = DateTime.now();
        final limit = Duration(milliseconds: waitMs + 6000);
        while (DateTime.now().difference(started) < limit) {
          final app = _required(read(), epoch, primary);
          if (app != null && !app.speechLinked) {
            throw SimInjectFailure(
              GlintErrorKind.unsupportedBackendAction,
              '${app.bundleId} does not use Apple\'s speech recognizer',
              'its process has no SFSpeechRecognizer, so there is no recognition for glint to stand in for',
              [
                'an app on the newer SpeechAnalyzer API is not covered; use an app that uses SFSpeechRecognizer (speech_to_text does)',
                '`media op:speech stop:true` removes the stand-in',
              ],
            );
          }
          if (app != null && app.ack >= seq && (app.taken >= seq || app.expired >= seq)) return app;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final now = read();
        final app = _required(now, epoch, primary);
        throw SimInjectFailure(
          app == null ? GlintErrorKind.appNotResumed : GlintErrorKind.appUnresponsive,
          app == null
              ? 'no app is in the foreground to take the speech'
              : 'the app did not apply the speech command in time',
          'apps holding the library: ${now.map((a) => a.bundleId).join(', ')}',
          [
            app == null
                ? 'bring the app to the foreground (attach, or open it), then repeat the call'
                : 'check the app is not frozen (get_scene), then repeat the call',
            '`media op:speech stop:true` then another `media op:speech text:"..."` loads glint again',
          ],
        );
      }

      final app = await (phases?.during('waiting for the app to start listening', reach) ?? reach());
      final taken = app.taken >= seq;
      var latest = app;
      var stopped = false;
      if (taken) {
        Future<void> deliver() async {
          final deadline = DateTime.now().add(Duration(milliseconds: (deliverySeconds * 1000).round()));
          while (DateTime.now().isBefore(deadline)) {
            if (!on) {
              stopped = true;
              return;
            }
            latest = _required(read(), epoch, primary) ?? latest;
            if (latest.settled >= seq) return;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }

        await (phases?.during('the app is receiving the results', deliver) ?? deliver());
      }
      return (
        app: latest,
        taken: taken,
        settled: taken && latest.settled >= seq,
        stopped: stopped,
        runs: latest.runsOf(seq),
        silent: [
          for (final a in read())
            if (a.epoch == epoch && a.bundleId != latest.bundleId) a.bundleId
        ],
      );
    } finally {
      if (on && _epoch == epoch) await injector.setModule(_moduleName, {'epoch': epoch, 'seq': seq});
    }
  }

  /// Turns the module off and removes what glint left for it; true when it was on.
  Future<bool> stop() => injector.stopModule(_moduleName);
}
