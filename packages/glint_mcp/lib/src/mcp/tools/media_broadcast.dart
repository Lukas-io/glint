import 'dart:io';

import '../../interaction/result.dart';
import '../../interaction/siminject.dart';
import '../../media/host_tools.dart';
import '../../media/media_generate.dart';
import '../../media/sim_broadcast.dart';
import '../../media/sim_camera.dart' show isImagePath;
import '../../media/testcard_generator.dart';
import '../envelope.dart';
import '../tool_args.dart';

const _actions = {'arm', 'start', 'pause', 'resume', 'status', 'stop'};

StructuredResponse _bad(String summary, {String? detail, List<String> nextSteps = const []}) =>
    StructuredResponse.error(
      summary: summary,
      errorKind: GlintErrorKind.invalidArgument,
      detail: detail,
      nextSteps: nextSteps,
    );

num _count(Map<String, Object?>? report, String key) => (report?[key] as num?) ?? 0;

Map<String, Object?> _delivered(Map<String, Object?>? report, Map<String, Object?> sources) {
  final video = report?['video'] as Map?;
  final started = (report?['startedAt'] as num?)?.toDouble();
  final ended = (report?['endedAt'] as num?)?.toDouble() ?? DateTime.now().millisecondsSinceEpoch / 1000;
  final seconds = started == null ? 0 : (ended - started).clamp(0.001, double.infinity);
  final frames = _count(report, 'videoDelivered');
  return {
    'video': {
      'count': frames,
      if (video != null) 'size': '${video['width']}x${video['height']}',
      if (video != null) 'pixelFormat': video['pixelFormat'],
      if (seconds >= 3) 'fps': double.parse((frames / seconds).toStringAsFixed(1)),
      'source': sources['video'],
      'synthetic': true,
    },
    'audioApp': {
      'count': _count(report, 'audioAppDelivered'),
      'format': '44100 Hz stereo 16-bit',
      'source': sources['audio'],
      'synthetic': true,
    },
    'audioMic': {'count': 0, 'note': 'the microphone stream is not delivered'},
  };
}

Map<String, Object?> _lifecycle(Map<String, Object?>? report) => {
      'broadcastStarted': report?['broadcastStarted'] == true,
      'broadcastFinished': report?['broadcastFinished'] == true,
      if (report?['finishError'] != null) 'finishBroadcastWithError': report!['finishError'],
      if (report?['exception'] != null) 'handlerException': report!['exception'],
      if (report?['updateServiceInfo'] != null) 'updateServiceInfo': report!['updateServiceInfo'],
      if (report?['updateBroadcastURL'] != null) 'updateBroadcastURL': report!['updateBroadcastURL'],
    };

const _fakedParts = [
  'replayd, the system broadcast service, is replaced by glint calling the handler directly',
  'the picker sheet and its countdown are skipped',
  'the extension runs without the 50 MB memory limit and with a glint-owned home folder',
  'sample timing follows the requested fps, not screen changes',
];

Map<String, Object?> _labels(Map<String, Object?>? config) => {
      'video': (config?['video'] as Map?)?['label'],
      'audio': (config?['audio'] as Map?)?['label'],
    };

String _sourcesLine(Map<String, Object?> sources) => '${sources['video']} video, ${sources['audio']} app audio';

/// The reply for a failure after glint cleaned up what the call had started.
String _cleaned(SimBroadcast bc) => bc.aborted
    ? '; glint stopped the screen helper and the extension, removed the broadcast setup and released the simulator (arm again to catch the picker)'
    : '';

Future<StructuredResponse> mediaBroadcast(
  Map<String, Object?> args,
  PhaseReporter phases, {
  required String id,
  required String? appId,
  required Future<StructuredResponse?> Function(String id) simBooted,
  required String Function(SimInjector injector) dormantNote,
}) async {
  final action = (args['action'] as String?) ?? (argBool(args, 'stop') == true ? 'stop' : 'start');
  if (!_actions.contains(action)) {
    return _bad('action must be arm, start, pause, resume, status or stop, got "$action"');
  }
  final injector = SimInjector(id, progress: phases);
  final bc = SimBroadcast(injector);
  try {
    await bc.cleanOrphan();
    if (action == 'status') return await _status(id, bc);
    final holder = bc.otherHolder();
    if (holder != null && argBool(args, 'force') != true) {
      return StructuredResponse.error(
        summary: 'another glint holds the broadcast of $id',
        errorKind: GlintErrorKind.deviceBusy,
        detail:
            'glint process ${holder.pid} has held it since ${holder.since.toIso8601String()}${holder.app == null || holder.app!.isEmpty ? '' : ' for ${holder.app}'}',
        nextSteps: const [
          'use another simulator for this broadcast',
          'or repeat the call with force:true to take it over (the other agent loses its run)',
        ],
      );
    }
    if (action == 'stop') return await _stop(id, bc, injector, dormantNote);
    final down = await simBooted(id);
    if (down != null) return down;
    var tookOver = false;
    if (holder != null) {
      await phases.during('ending the other glint\'s broadcast', bc.takeOver);
      tookOver = true;
    }
    return switch (action) {
      'arm' => await _arm(id, bc, injector, args, appId),
      'pause' || 'resume' => await _pause(id, bc, action == 'pause'),
      _ => await _start(id, bc, injector, args, phases, appId, tookOver),
    };
  } on SimInjectFailure catch (e) {
    return StructuredResponse.error(
      summary: e.message,
      errorKind: e.kind,
      detail: '${e.detail}${_cleaned(bc)}',
      nextSteps: e.nextSteps,
    );
  } on MissingHostTool catch (e) {
    return StructuredResponse.error(
      summary: 'broadcast needs ${e.binary}, which is not available on the host',
      errorKind: GlintErrorKind.unsupportedToolchain,
      detail: '${e.toString()}${_cleaned(bc)}',
      nextSteps: const ['install it, or feed an image or video file as source'],
    );
  }
}

Future<StructuredResponse> _status(String id, SimBroadcast bc) async {
  final report = bc.report();
  final config = bc.config();
  final press = await bc.pickerPress();
  final running = await bc.busy();
  final died = !running && report != null;
  final audioError = report?['audioError'];
  final ownEnd = report?['state'] == 'finishedByExtension';
  final state = running ? (report?['state'] ?? 'starting') : (died ? 'exited' : (config == null ? 'off' : 'armed'));
  final shown = running || died;
  return StructuredResponse(
    summary: running
        ? 'the broadcast extension is $state: ${_count(report, 'videoDelivered')} video frames and ${_count(report, 'audioAppDelivered')} app audio buffers delivered so far'
        : ownEnd
            ? 'the extension ended the broadcast itself with finishBroadcastWithError (${(report?['finishError'] as Map?)?['message'] ?? 'no error'}) after ${_count(report, 'videoDelivered')} video frames'
            : died
                ? 'the broadcast extension process exited without being stopped (last state ${report['state']}, ${_count(report, 'videoDelivered')} video frames delivered as of its last report)'
                : config == null
                    ? 'no broadcast is set up on $id'
                    : 'the broadcast is armed on $id; no extension is running${press == null ? '' : ' and the app pressed its picker'}',
    warnings: [
      if (audioError != null) 'the app audio source failed and no audio is delivered: $audioError',
    ],
    nextSteps: [
      if (running) '`media op:broadcast action:stop` ends it (the handler gets broadcastFinished)',
      if (died) '`media op:broadcast action:stop` removes what is left, then `media op:broadcast` runs it again',
      if (died && !ownEnd)
        'the extension crashed or called exit; `app_logs` or its crash report in Console.app names why',
      if (!running && !died && press != null) '`media op:broadcast` answers the picker press and runs the extension',
      if (!running && !died && press == null && config != null)
        'tap the app\'s start-broadcast control, then `media op:broadcast`',
      if (!running && !died && config == null) '`media op:broadcast` runs the app\'s upload extension',
    ],
    data: {
      'device': id,
      'state': state,
      'running': running,
      if (shown && report != null) 'lifecycle': _lifecycle(report),
      if (shown && report != null) 'delivered': _delivered(report, _labels(config)),
      if (died && bc.logTail().isNotEmpty) 'extensionOutput': bc.logTail(),
      if (audioError != null) 'audioError': audioError,
      if (press != null)
        'pickerPress': {
          'bundleId': press.bundleId,
          'preferredExtension': press.preferredExtension,
          'showsMicrophoneButton': press.showsMicrophone,
          'secondsAgo': DateTime.now().difference(press.at).inSeconds,
        },
    },
  );
}

Future<StructuredResponse> _arm(
  String id,
  SimBroadcast bc,
  SimInjector injector,
  Map<String, Object?> args,
  String? appId,
) async {
  if (appId == null) return _noApp();
  if (await bc.busy()) {
    return StructuredResponse.error(
      summary: 'a broadcast is running on $id; stop it first',
      errorKind: GlintErrorKind.deviceBusy,
      detail: 'arming would replace the live broadcast setup',
      nextSteps: const ['`media op:broadcast action:stop` ends it, then arm again'],
    );
  }
  final report = await injector.ensure(appId: appId, relaunch: argBool(args, 'relaunch') == true, module: 'broadcast');
  await bc.arm(appId);
  final waiting = report.waiting.isEmpty ? '' : '; start the app first';
  return StructuredResponse(
    summary:
        'glint answers the broadcast picker of $appId$waiting. injected: broadcast, ${report.load.name}. Nothing runs yet.',
    warnings: [
      if (report.load == InjectLoad.lateLoad)
        'the app was already running, so a socket it bound before this call keeps its long app group path',
    ],
    nextSteps: [
      if (report.waiting.isNotEmpty) 'launch $appId (attach launch:"$appId")',
      if (report.relaunched.isNotEmpty) 'attach again: the app restarted',
      'tap the app\'s start-broadcast control, then `media op:broadcast` runs its extension',
    ],
    data: {
      'device': id,
      'pickerIntercepted': true,
      'injected': report.toJson(modules: const ['broadcast'])
    },
  );
}

StructuredResponse _noApp() => _bad(
      'broadcast needs the app whose extension to run',
      nextSteps: const ['attach the app first, or pass appId:"<bundle id>"'],
    );

Future<StructuredResponse> _pause(String id, SimBroadcast bc, bool paused) async {
  final outcome = await bc.setPaused(paused);
  switch (outcome) {
    case PauseOutcome.notRunning:
      return StructuredResponse.error(
        summary: 'no broadcast extension is running on $id',
        errorKind: GlintErrorKind.targetNotFound,
        nextSteps: const ['`media op:broadcast` runs the app\'s upload extension first'],
      );
    case PauseOutcome.unconfirmed:
      return StructuredResponse.error(
        summary: 'the handler did not confirm ${paused ? 'broadcastPaused' : 'broadcastResumed'} within 10 s',
        errorKind: GlintErrorKind.toolTimeout,
        detail:
            'glint asked the extension, which is still running, but its report did not change to ${paused ? 'paused' : 'running'}; the handler may be busy or blocked in its own code',
        nextSteps: const [
          '`media op:broadcast action:status` shows the state the extension reports',
          'repeat the call once the handler is idle, or `action:stop` to end the broadcast',
        ],
      );
    case PauseOutcome.confirmed:
      return StructuredResponse(
        summary: paused
            ? 'the handler got broadcastPaused and confirmed it; no samples are delivered until you resume'
            : 'the handler got broadcastResumed and confirmed it; samples flow again',
        nextSteps: [
          paused ? '`media op:broadcast action:resume` continues' : '`media op:broadcast action:stop` ends it',
        ],
        data: {'device': id, 'paused': paused, 'lifecycle': _lifecycle(bc.report())},
      );
  }
}

Future<StructuredResponse> _stop(
  String id,
  SimBroadcast bc,
  SimInjector injector,
  String Function(SimInjector) dormantNote,
) async {
  final end = await bc.stop();
  final holding = [for (final a in injector.loaded()) a.bundleId];
  final clean = dormantNote(injector);
  final report = end.report;
  if (end.end == ExtensionEnd.unconfirmed) {
    return StructuredResponse.error(
      summary: 'glint could not confirm the broadcast extension (pid ${end.extensionPid}) is gone',
      errorKind: GlintErrorKind.backendToolError,
      detail: 'it did not exit after a terminate and a kill signal sent inside the simulator',
      nextSteps: [
        'xcrun simctl spawn $id kill -KILL ${end.extensionPid}',
        'or shut the simulator down (`shutdown_sim`)',
      ],
    );
  }
  if (!end.wasRunning && report == null) {
    return StructuredResponse(
      summary: 'no broadcast was running on $id; glint removed what it had set up. $clean',
      nextSteps: const ['`media op:broadcast` runs the app\'s upload extension'],
      data: {'device': id, 'stopped': true, 'stillLoaded': holding},
    );
  }
  final finished = report?['broadcastFinished'] == true;
  final byExtension = report?['finishError'] != null;
  final how = switch (end.end) {
    ExtensionEnd.terminated => 'it did not exit on its own and glint terminated it',
    ExtensionEnd.killed => 'it ignored a terminate and glint killed it',
    _ => 'it exited',
  };
  return StructuredResponse(
    summary:
        '${byExtension ? 'the extension ended the broadcast itself' : finished ? 'the handler got broadcastFinished' : 'the broadcast ended without broadcastFinished'}; '
        '${_count(report, 'videoDelivered')} video frames and ${_count(report, 'audioAppDelivered')} app audio buffers were delivered. '
        'The extension process (pid ${end.extensionPid ?? 'unknown'}) is gone, checked after the stop: $how. glint removed its folders and helpers${end.linksKept ? '; the short app group links under ${bc.shortRoot} stay until the app exits, because it may hold one (they point at its real folder)' : ' and links'}. $clean.',
    warnings: [
      if (end.end == ExtensionEnd.terminated || end.end == ExtensionEnd.killed)
        'the extension did not exit within ${end.end == ExtensionEnd.killed ? '14' : '10'} s of the stop request and glint ended it',
      if (end.log.isNotEmpty && report?['exception'] != null) 'extension output: ${end.log}',
    ],
    nextSteps: const ['`media op:broadcast` runs it again'],
    data: {
      'device': id,
      'stopped': true,
      'delivered': _delivered(report, end.labels),
      'lifecycle': _lifecycle(report),
      'extensionProcess': {'pid': end.extensionPid, 'gone': true, 'ended': end.end.name},
      'shortLinks': {'kept': end.linksKept, if (end.linksKept) 'root': bc.shortRoot},
      'stillLoaded': holding,
    },
  );
}

UploadExtension? _pick(List<UploadExtension> found, String? wanted) {
  if (wanted != null) return found.where((e) => e.bundleId == wanted).firstOrNull;
  return found.length == 1 ? found.single : null;
}

({int width, int height})? _size(String? text) {
  final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(text ?? '');
  return m == null ? null : (width: int.parse(m.group(1)!), height: int.parse(m.group(2)!));
}

Future<StructuredResponse> _start(
  String id,
  SimBroadcast bc,
  SimInjector injector,
  Map<String, Object?> args,
  PhaseReporter phases,
  String? appId,
  bool tookOver,
) async {
  try {
    return await _run(id, bc, injector, args, phases, appId, tookOver);
  } on Object {
    await bc.abortStart();
    rethrow;
  }
}

StructuredResponse _failedStart(SimBroadcast bc, String bundleId, StartOutcome outcome) {
  final report = outcome.report;
  final failure = report?['failure'] as Map?;
  final exception = report?['exception'] as Map?;
  final error = report?['finishError'] as Map?;
  final counts =
      '${_count(report, 'videoDelivered')} video frames and ${_count(report, 'audioAppDelivered')} audio buffers as of the last report';
  final exit = outcome.exitCode == null ? '' : ' (host process exit code ${outcome.exitCode})';
  final tail = outcome.log.isEmpty ? '' : '\nextension output:\n${outcome.log}';
  final (String summary, String detail, List<String> steps) = switch (outcome.kind) {
    StartKind.finishedByExtension => (
        '$bundleId ended the broadcast itself before it ran',
        'finishBroadcastWithError: ${error?['domain']} ${error?['code']}: ${error?['message']}; $counts$tail',
        ['the extension chose to stop; its own code or setup explains it (app group, socket, permissions in its code)'],
      ),
    StartKind.crashed => (
        '$bundleId crashed before samples flowed',
        'the extension process is gone$exit; last state ${report?['state']}; $counts$tail',
        ['`app_logs` or the crash report in Console.app names the cause'],
      ),
    StartKind.ended => (
        '$bundleId was ended before samples flowed',
        'the extension got broadcastFinished and exited$exit; $counts$tail',
        ['repeat the call'],
      ),
    StartKind.failed => (
        '$bundleId did not start: ${failure != null ? '${failure['reason']}' : exception != null ? '${exception['in']} threw ${exception['name']}' : outcome.reason ?? 'it reported a failure'}',
        '${failure != null ? '${failure['detail']}' : exception != null ? '${exception['reason']}' : outcome.reason ?? 'no detail'}$tail',
        ['check the extension\'s Info.plist principal class and that it was built for the simulator'],
      ),
    _ => (
        '$bundleId started but a requested stream never delivered within 90 s',
        '${outcome.reason ?? 'the extension process stayed alive but delivered nothing'}; last state ${report?['state']}, $counts$tail',
        ['the handler may be blocked in broadcastStarted; `app_logs` shows what it printed'],
      ),
  };
  return StructuredResponse.error(
    summary: summary,
    errorKind: GlintErrorKind.backendToolError,
    detail: '$detail${_cleaned(bc)}',
    nextSteps: [...steps, 'repeat the call once; glint removed everything it had set up'],
  );
}

Future<StructuredResponse> _run(
  String id,
  SimBroadcast bc,
  SimInjector injector,
  Map<String, Object?> args,
  PhaseReporter phases,
  String? appId,
  bool tookOver,
) async {
  if (appId == null) return _noApp();
  if (await bc.busy()) {
    return StructuredResponse.error(
      summary: 'a broadcast extension is already running on $id',
      errorKind: GlintErrorKind.deviceBusy,
      nextSteps: const [
        '`media op:broadcast action:stop` ends it first',
        '`media op:broadcast action:status` shows it',
      ],
    );
  }
  final fps = argInt(args, 'fps') ?? 15;
  if (fps < 1 || fps > 60) return _bad('fps must be between 1 and 60, got $fps');
  final sizeText = args['size'] as String?;
  final size = _size(sizeText);
  if (sizeText != null && size == null) return _bad('size must be WxH such as 1170x2532, got "$sizeText"');
  final seen = await bc.pickerPress();
  final press = seen != null && seen.bundleId == appId ? seen : null;
  final found = await bc.uploadExtensions(appId);
  if (found == null) {
    return StructuredResponse.error(
      summary: '$appId is not installed on $id',
      errorKind: GlintErrorKind.targetNotFound,
      nextSteps: const ['install the app (attach launch:"<bundle id>" or flutter run), then repeat the call'],
    );
  }
  final wanted = (args['extension'] as String?) ?? press?.preferredExtension;
  final extension = _pick(found, wanted);
  if (extension == null) {
    final names = [for (final e in found) e.bundleId];
    return StructuredResponse.error(
      summary: found.isEmpty
          ? '$appId has no broadcast upload extension'
          : wanted != null
              ? '$appId has no broadcast upload extension "$wanted"'
              : '$appId has ${found.length} broadcast upload extensions',
      errorKind: found.isEmpty || wanted != null ? GlintErrorKind.targetNotFound : GlintErrorKind.invalidArgument,
      detail: found.isEmpty
          ? 'its PlugIns folder holds no extension with the point com.apple.broadcast-services-upload'
          : 'found: ${names.join(', ')}',
      nextSteps: found.isEmpty
          ? const ['build the app with its broadcast upload extension target embedded, then reinstall']
          : ['repeat the call with extension:"<one of ${names.join(' | ')}>"'],
    );
  }
  final audioArg = (args['audio'] as String?) ?? 'tone';
  if (audioArg != 'tone' && audioArg != 'none' && !File(audioArg).existsSync()) {
    return _bad('audio must be tone, none or an audio file path; "$audioArg" does not exist');
  }
  final source = (args['source'] as String?) ?? 'screen';
  if (source != 'screen' && source != 'testcard' && !File(source).existsSync()) {
    return _bad('source must be screen, testcard or an image or video path; "$source" does not exist');
  }
  Map<String, Object?> video;
  final String videoLabel;
  var width = size?.width;
  var height = size?.height;
  if (source == 'screen') {
    videoLabel = 'the simulator screen';
    video = const {};
  } else if (source == 'testcard') {
    final file = await generateTestCardVideo(
      const TestCardSpec(width: 720, height: 1280, durationSec: 10, fps: 30),
      'glint-broadcast-testcard',
      phases: phases,
    );
    videoLabel = 'the glint test card';
    video = {'kind': 'video', 'path': file.path, 'label': videoLabel};
  } else {
    final file = File(source);
    videoLabel = file.uri.pathSegments.last;
    video = {'kind': isImagePath(file.path) ? 'image' : 'video', 'path': file.absolute.path, 'label': videoLabel};
  }
  final audioLabel = audioArg == 'tone'
      ? 'a ${argNum(args, 'hz') ?? 440} Hz tone'
      : audioArg == 'none'
          ? 'no'
          : File(audioArg).uri.pathSegments.last;
  final audio = audioArg == 'tone'
      ? {'kind': 'tone', 'hz': argNum(args, 'hz') ?? 440, 'label': audioLabel}
      : audioArg == 'none'
          ? {'kind': 'none', 'label': audioLabel}
          : {'kind': 'file', 'path': File(audioArg).absolute.path, 'label': audioLabel};
  var appSide = true;
  InjectReport? injected;
  try {
    injected = await injector.ensure(appId: appId, relaunch: argBool(args, 'relaunch') == true, module: 'broadcast');
  } on SimInjectFailure catch (e) {
    if (e.kind != GlintErrorKind.unsupportedBackendAction) rethrow;
    appSide = false;
  }
  final dylib = await injector.dylibPath();
  if (source == 'screen') {
    final screen = await bc.startScreen(phases, fps: fps);
    video = {'kind': 'webcam', 'path': screen.path, 'staleSec': 8, 'label': videoLabel};
    final native = _size(screen.size);
    width ??= native?.width;
    height ??= native?.height;
  }
  final plan = (
    appId: appId,
    extension: extension,
    video: video,
    audio: audio,
    fps: fps,
    width: width,
    height: height,
  );
  final outcome = await bc.start(plan, dylib, phases);
  if (outcome.kind != StartKind.running) {
    await bc.abortStart();
    return _failedStart(bc, extension.bundleId, outcome);
  }
  final report = outcome.report;
  if (appSide) await bc.setCapturing(plan, true);
  final sources = {'video': videoLabel, 'audio': audioLabel};
  final answered = press != null;
  return StructuredResponse(
    summary:
        '${extension.bundleId} ${answered ? 'answered the app\'s picker: ' : ''}ran broadcastStarted and receives ${_sourcesLine(sources)} '
        '(${_count(report, 'videoDelivered')} frames, ${_count(report, 'audioAppDelivered')} audio buffers so far). '
        'Synthetic: ${_fakedParts.first}. injected: broadcast${injected == null ? ', not loaded into the app' : ', ${injected.load.name}'}.',
    warnings: [
      if (tookOver) 'another glint held this simulator\'s broadcast; glint ended its extension and took over',
      if (seen != null && press == null)
        'the pending picker press came from ${seen.bundleId}, not $appId; glint left it unanswered',
      if (!appSide)
        '$appId started before glint could load into it, so its UIScreen.isCaptured stays false, its picker press is not caught and its app group folder keeps the long path (a Unix socket there fails with "path too long"); repeat with relaunch:true to load glint into the app',
      if (injected?.load == InjectLoad.lateLoad)
        'the app was already running, so a socket it bound before this call keeps its long app group path',
      if (source == 'screen')
        'the screen source delivers a new picture as often as simctl screenshots finish, paced to $fps per second at most (about 1 to 3 on a loaded Mac); the extension gets the latest picture at $fps fps',
    ],
    nextSteps: [
      if (injected?.relaunched.isNotEmpty == true) 'attach again: the app restarted',
      '`media op:broadcast action:status` shows the counts; the app can read its own log or socket',
      '`media op:broadcast action:pause` / `resume` call broadcastPaused / broadcastResumed',
      '`media op:broadcast action:stop` ends it (broadcastFinished) and removes everything glint set up',
    ],
    data: {
      'device': id,
      'running': true,
      'extension': {'bundleId': extension.bundleId, 'name': extension.name, 'pid': outcome.pid},
      'delivered': _delivered(report, sources),
      'lifecycle': _lifecycle(report),
      'appSees': {'screenCaptured': appSide, 'synthetic': true},
      'pickerAnswered': answered,
      'shortAppGroupPath': {
        'root': bc.shortRoot,
        'why': 'the simulator app group path is over the 104 byte limit of a Unix socket path',
      },
      'synthetic': _fakedParts,
      if (injected != null) 'injected': injected.toJson(modules: const ['broadcast']),
    },
  );
}
