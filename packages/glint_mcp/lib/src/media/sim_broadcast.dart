import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart' show HelperLife, ProcessRegistry;

import '../interaction/bounded_process.dart';
import '../interaction/device_claims.dart';
import '../interaction/result.dart';
import '../interaction/siminject.dart';
import '../observability/call_progress.dart';
import 'frame_helper.dart';
import 'host_tools.dart';

const _module = 'broadcast';
const _uploadPoint = 'com.apple.broadcast-services-upload';
const _stopGrace = Duration(seconds: 10);
const _extensionPurpose = 'broadcast-extension';

/// A broadcast upload extension inside an installed app.
typedef UploadExtension = ({String bundleId, String executable, String name});

/// What a broadcast run was told to deliver.
typedef BroadcastPlan = ({
  String appId,
  UploadExtension extension,
  Map<String, Object?> video,
  Map<String, Object?> audio,
  int fps,
  int? width,
  int? height,
});

/// A press of the app's broadcast picker that glint caught and has not answered yet.
typedef PickerPress = ({String bundleId, String? preferredExtension, bool showsMicrophone, DateTime at});

/// How a start ended, from the process, the last report and the delivered counts together.
enum StartKind { running, finishedByExtension, crashed, ended, failed, stalled }

/// The real final state of a start attempt.
typedef StartOutcome = ({
  StartKind kind,
  Map<String, Object?>? report,
  int? exitCode,
  String log,
  int? pid,
  String? reason,
});

/// Whether the handler confirmed a pause or resume.
enum PauseOutcome { confirmed, notRunning, unconfirmed }

/// How glint ended an extension process: it was already gone, exited on its own, took a polite signal, needed a kill, or could not be confirmed gone.
enum ExtensionEnd { gone, exited, terminated, killed, unconfirmed }

/// What a stop found and removed.
typedef StopResult = ({
  Map<String, Object?>? report,
  String log,
  bool wasRunning,
  Map<String, Object?> labels,
  int? extensionPid,
  ExtensionEnd end,
  bool linksKept,
});

/// What a pid is now compared with the extension glint expects: not running, that process, another process, or not decidable because the expected name is unknown.
enum PidState { gone, match, other, unknown }

/// glint's stand-in for ReplayKit on an iOS simulator: it runs an app's broadcast upload extension as a host process, calls its `RPBroadcastSampleHandler` lifecycle and feeds it sample buffers, through the injected library's `broadcast` module.
class SimBroadcast {
  SimBroadcast(this.injector);

  final SimInjector injector;

  bool _began = false;

  bool _aborted = false;

  String get _dir => '${injector.controlDir}/broadcast';

  String get _frames => '${injector.controlDir}/screen.frames';

  String get _pausedFile => '$_dir/paused';

  /// The short path glint links app group folders under, so Unix socket paths fit `sun_path`.
  String get shortRoot => '/tmp/gbc-${injector.udid.substring(0, 8)}';

  DeviceClaims get _claims => DeviceClaims(dir: '${injector.controlDir}/broadcast-claims');

  /// The glint process holding this simulator's broadcast if another live one does, else null.
  DeviceClaim? otherHolder() => _claims.heldByOther(injector.udid);

  /// Whether this call started something that [abortStart] would have to undo.
  bool get began => _began;

  /// Whether [abortStart] undid a start of this call.
  bool get aborted => _aborted;

  /// Whether the extension host process glint started is running.
  bool get running => ProcessRegistry.instance.processFor('broadcast', device: injector.udid) != null;

  /// Whether a broadcast is on: our host process runs, or the extension of an earlier run is still alive.
  Future<bool> busy() async => running || await extensionAlive();

  /// What the module is set to now, or null when it is off.
  Map<String, Object?>? config() => injector.moduleConfig(_module);

  /// The extension's own account of the run, or null before it wrote one.
  Map<String, Object?>? report() => _readJson('$_dir/report.json');

  /// The pid of the extension process the last report names.
  int? extensionPid() => (report()?['pid'] as num?)?.toInt();

  /// The last lines the extension process printed.
  String logTail([int lines = 8]) {
    final file = File('$_dir/extension.log');
    if (!file.existsSync()) return '';
    final all = file.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  }

  Map<String, Object?>? _readJson(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    } on Object {
      return null;
    }
  }

  /// The executable name of the extension glint expects: the config's, else the last report's, else the one in the installed app bundle.
  Future<String?> expectedName() async {
    final fromConfig = config()?['extensionExe'] as String?;
    if (fromConfig != null && fromConfig.isNotEmpty) return fromConfig;
    final r = report();
    final fromReport = r?['executable'] as String?;
    if (fromReport != null && fromReport.isNotEmpty) return fromReport;
    final app = config()?['appId'] as String?;
    final bundle = r?['bundleId'] as String?;
    if (app == null || bundle == null) return null;
    final found = await uploadExtensions(app);
    return found?.where((e) => e.bundleId == bundle).firstOrNull?.executable.split('/').last;
  }

  PidState _stateIn(Map<int, String> names, int? target, String? expected) {
    if (target == null || !names.containsKey(target)) return PidState.gone;
    if (expected == null || expected.isEmpty) return PidState.unknown;
    return names[target]!.endsWith('/$expected') ? PidState.match : PidState.other;
  }

  /// What the extension pid in the last report is now, from one `ps`.
  Future<PidState> extensionState([int? target]) async {
    final pidNow = target ?? extensionPid();
    if (pidNow == null) return PidState.gone;
    return _stateIn(await injector.processNames([pidNow]), pidNow, await expectedName());
  }

  Future<PidState> _stateOfPid(int target, String? expected) async =>
      _stateIn(await injector.processNames([target]), target, expected);

  /// Whether the extension process is alive, or cannot be told from another process.
  Future<bool> extensionAlive() async {
    final state = await extensionState();
    return state == PidState.match || state == PidState.unknown;
  }

  /// The app's broadcast picker press waiting for an answer, or null.
  Future<PickerPress?> pickerPress() async {
    final j = _readJson('$_dir/picker.json');
    if (j == null) return null;
    final pressedBy = (j['pid'] as num?)?.toInt();
    if (pressedBy == null || !(await injector.processNames([pressedBy])).containsKey(pressedBy)) return null;
    return (
      bundleId: (j['bundleId'] as String?) ?? '',
      preferredExtension: j['preferredExtension'] as String?,
      showsMicrophone: j['showsMicrophoneButton'] == true,
      at: DateTime.fromMillisecondsSinceEpoch(((j['at'] as num).toDouble() * 1000).round()),
    );
  }

  /// Marks the picker press as answered.
  void clearPickerPress() {
    final file = File('$_dir/picker.json');
    if (file.existsSync()) file.deleteSync();
  }

  Future<String?> _appPath(String appId) async {
    final r = await runBounded('xcrun', ['simctl', 'get_app_container', injector.udid, appId],
        timeout: const Duration(seconds: 30), phase: 'finding $appId on the simulator');
    final path = '${r.stdout}'.trim();
    return r.exitCode == 0 && path.isNotEmpty ? path : null;
  }

  /// The broadcast upload extensions inside [appId], or null when the app is not installed.
  Future<List<UploadExtension>?> uploadExtensions(String appId) async {
    final app = await _appPath(appId);
    if (app == null) return null;
    final plugins = Directory('$app/PlugIns');
    if (!plugins.existsSync()) return const [];
    final found = <UploadExtension>[];
    for (final dir in plugins.listSync().whereType<Directory>().where((d) => d.path.endsWith('.appex'))) {
      final r = await runBounded('plutil', ['-convert', 'json', '-o', '-', '${dir.path}/Info.plist'],
          timeout: const Duration(seconds: 15),
          phase: 'reading ${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}');
      if (r.exitCode != 0) continue;
      final info = jsonDecode('${r.stdout}') as Map<String, Object?>;
      final ext = info['NSExtension'];
      if (ext is! Map || ext['NSExtensionPointIdentifier'] != _uploadPoint) continue;
      final exe = info['CFBundleExecutable'] as String?;
      final id = info['CFBundleIdentifier'] as String?;
      if (exe == null || id == null) continue;
      found.add((
        bundleId: id,
        executable: '${dir.path}/$exe',
        name: (info['CFBundleDisplayName'] ?? info['CFBundleName'] ?? id) as String,
      ));
    }
    return found;
  }

  void _claim(String showing) {
    injector.prepareControlDir();
    _claims.claim(injector.udid, app: showing);
  }

  Map<String, Object?> _config(BroadcastPlan plan, {required bool capturing, bool paused = false}) => {
        'appId': plan.appId,
        'extension': plan.extension.bundleId,
        'extensionExe': plan.extension.executable.split('/').last,
        'ownerPid': pid,
        'shortPaths': shortRoot,
        'capturing': capturing,
        'paused': paused,
        'fps': plan.fps,
        if (plan.width != null) 'width': plan.width,
        if (plan.height != null) 'height': plan.height,
        'video': plan.video,
        'audio': plan.audio,
      };

  /// Intercepts the app's broadcast picker and links its app group folders under a short path, without running anything; the caller has checked nothing is running.
  Future<void> arm(String appId) async {
    _claim('$appId broadcast picker');
    final stale = Directory(_dir);
    if (stale.existsSync() && !await busy()) stale.deleteSync(recursive: true);
    await injector.setModule(_module, {'appId': appId, 'ownerPid': pid, 'shortPaths': shortRoot, 'capturing': false});
  }

  /// Starts the screen helper, paced to [fps], and returns the frame file the extension host reads and the screen size.
  Future<({String path, String size})> startScreen(PhaseReporter? phases, {required int fps}) async {
    _began = true;
    final helper = await frameHelperBinary(phases);
    injector.prepareControlDir();
    Directory(_dir).createSync(recursive: true);
    await stopScreen();
    final started = await startFrameHelper(
      binary: helper,
      purpose: 'screen',
      device: injector.udid,
      arguments: ['screen', injector.udid, _frames, '$fps', _pausedFile],
      label: 'the simulator screen helper',
      waiting: 'reading the simulator screen',
      timeout: const Duration(seconds: 60),
      phases: phases,
      notReady: (line) => SimInjectFailure(
        GlintErrorKind.backendToolError,
        'glint could not read the screen of ${injector.udid}',
        line == 'timeout' ? 'no screenshot arrived within 60 s' : line,
        ['check the simulator is booted and unlocked (xcrun simctl io ${injector.udid} screenshot /tmp/x.png)'],
      ),
    );
    final size = RegExp(r'(\d+x\d+)').firstMatch(started.line)?.group(1);
    if (size == null) {
      await stopScreen();
      throw SimInjectFailure(
          GlintErrorKind.backendToolError,
          'glint could not read the screen size of ${injector.udid}',
          started.line,
          ['check the simulator is booted and unlocked']);
    }
    return (path: _frames, size: size);
  }

  /// Stops the screen helper and deletes its frames.
  Future<void> stopScreen() async {
    await ProcessRegistry.instance.stop('screen', device: injector.udid);
    for (final name in const ['screen.frames', 'screen.frames.png', 'screen.frames.tmp', 'screen.frames.read']) {
      final file = File('${injector.controlDir}/$name');
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Ends the extension process [target] and confirms it is gone from the pid table and from the simulator's launchd: a polite signal first, a kill after a bound; it is signalled only while it is the extension [expected] names, and never when that name is unknown.
  Future<ExtensionEnd> endExtension(int target, String? expected) async {
    var names = await injector.processNames([target]);
    switch (_stateIn(names, target, expected)) {
      case PidState.gone || PidState.other:
        return ExtensionEnd.gone;
      case PidState.unknown:
        return ExtensionEnd.unconfirmed;
      case PidState.match:
        break;
    }
    Future<bool> waitGone(Duration within) async {
      final deadline = DateTime.now().add(within);
      while (DateTime.now().isBefore(deadline)) {
        names = await injector.processNames([target]);
        if (_stateIn(names, target, expected) != PidState.match) return true;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return false;
    }

    Process.runSync('kill', ['-TERM', '$target']);
    if (await waitGone(const Duration(seconds: 4))) return await _confirmedGone(target, ExtensionEnd.terminated);
    Process.runSync('kill', ['-KILL', '$target']);
    return await waitGone(const Duration(seconds: 3))
        ? await _confirmedGone(target, ExtensionEnd.killed)
        : ExtensionEnd.unconfirmed;
  }

  Future<ExtensionEnd> _confirmedGone(int target, ExtensionEnd how) async {
    final listed = await runBounded('xcrun', ['simctl', 'spawn', injector.udid, 'launchctl', 'list'],
        timeout: const Duration(seconds: 15), phase: 'checking the simulator no longer runs the extension');
    final stillThere = '${listed.stdout}'.split('\n').any((l) => l.trimLeft().startsWith('$target\t'));
    return stillThere ? ExtensionEnd.unconfirmed : how;
  }

  /// Runs the extension of [plan]: turns the module on, starts the host process and waits until the handler ran `broadcastStarted` and every requested stream has delivered, or the run ends. Returns what really happened.
  Future<StartOutcome> start(BroadcastPlan plan, String dylib, PhaseReporter? phases) async {
    _began = true;
    _claim('${plan.appId} broadcast');
    final exe = plan.extension.executable.split('/').last;
    final stalePid = extensionPid();
    if (stalePid != null) await endExtension(stalePid, await expectedName() ?? exe);
    final dir = Directory(_dir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    Directory('$_dir/home/tmp').createSync(recursive: true);
    await injector.setModule(_module, _config(plan, capturing: false));
    final home = '$_dir/home';
    final log = '$_dir/extension.log';
    final process = await startHelper(
      'broadcast',
      '/bin/sh',
      ['-c', 'exec "\$0" "\$@" >> "$log" 2>&1', 'xcrun', 'simctl', 'spawn', injector.udid, plan.extension.executable],
      device: injector.udid,
      life: HelperLife.session,
      label: 'the broadcast extension ${plan.extension.bundleId}',
      environment: {
        'SIMCTL_CHILD_DYLD_INSERT_LIBRARIES': dylib,
        'SIMCTL_CHILD_GLINT_BROADCAST_HOST': '1',
        'SIMCTL_CHILD_HOME': home,
        'SIMCTL_CHILD_CFFIXED_USER_HOME': home,
        'SIMCTL_CHILD_TMPDIR': '$home/tmp/',
      },
    );
    int? exitCode;
    unawaited(process.exitCode.then((c) => exitCode = c));
    var adopted = false;
    final wantsAudio = plan.audio['kind'] != 'none';

    Future<void> adoptPid(int target) async {
      if (adopted) return;
      adopted = true;
      await ProcessRegistry.instance
          .adopt(target, _extensionPurpose, device: injector.udid, life: HelperLife.session, owner: plan.appId);
    }

    String? stalledReason(Map<String, Object?>? r) {
      if (((r?['videoDelivered'] as num?) ?? 0) == 0) {
        if (plan.video['kind'] == 'webcam') {
          return ProcessRegistry.instance.processFor('screen', device: injector.udid) == null
              ? 'no video frame arrived and the screen helper exited (it stops on its own when nothing reads its frames for 10 s)'
              : 'no video frame arrived: the screen helper runs but the extension read no picture from it';
        }
        return 'no video frame arrived from the ${plan.video['label']} source';
      }
      if (wantsAudio && ((r?['audioAppDelivered'] as num?) ?? 0) == 0) {
        return 'no app audio buffer arrived from the ${plan.audio['label']} source';
      }
      return null;
    }

    Future<StartOutcome> settle(StartKind Function() kind, {int? target, String? reason}) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final r = report();
      return (
        kind: kind(),
        report: r,
        exitCode: exitCode,
        log: logTail(),
        pid: target ?? extensionPid(),
        reason: reason ?? stalledReason(r),
      );
    }

    Future<StartOutcome> wait() async {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        final r = report();
        final target = (r?['pid'] as num?)?.toInt();
        if (target != null) await adoptPid(target);
        final state = r?['state'];
        final video = (r?['videoDelivered'] as num?) ?? 0;
        final audio = (r?['audioAppDelivered'] as num?) ?? 0;
        final pidState =
            target == null ? PidState.unknown : _stateIn(await injector.processNames([target]), target, exe);
        final alive = pidState == PidState.match;
        if (state == 'failed') return settle(() => StartKind.failed, target: target);
        if (r?['audioError'] != null && plan.audio['kind'] == 'file') {
          return settle(() => StartKind.failed, target: target, reason: 'audioError: ${r!['audioError']}');
        }
        if (exitCode != null || (target != null && !alive)) {
          return settle(() => _exitKind(report()), target: target);
        }
        if (state == 'running' && video > 0 && (!wantsAudio || audio > 0) && alive) {
          return (kind: StartKind.running, report: r, exitCode: null, log: '', pid: target, reason: null);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return settle(() => StartKind.stalled);
    }

    final outcome =
        await (phases?.during('starting ${plan.extension.bundleId} and waiting for its first samples', wait) ?? wait());
    CallProgress.release(process);
    return outcome;
  }

  StartKind _exitKind(Map<String, Object?>? r) {
    final state = r?['state'];
    if (r?['finishError'] != null || state == 'finishedByExtension') return StartKind.finishedByExtension;
    if (state == 'finished') return StartKind.ended;
    if (state == 'failed') return StartKind.failed;
    return StartKind.crashed;
  }

  /// Tells the module the app now sees (or no longer sees) a screen being captured.
  Future<void> setCapturing(BroadcastPlan plan, bool capturing) async {
    await injector.setModule(_module, _config(plan, capturing: capturing));
  }

  /// Pauses or resumes sample delivery with the matching handler calls, and says whether the handler confirmed it.
  Future<PauseOutcome> setPaused(bool paused) async {
    final current = config();
    if (current == null || !running || !await extensionAlive()) return PauseOutcome.notRunning;
    final flag = File(_pausedFile);
    if (paused) {
      flag.writeAsStringSync('1');
    } else if (flag.existsSync()) {
      flag.deleteSync();
    }
    await injector.setModule(_module, {...current, 'paused': paused});
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (report()?['state'] == (paused ? 'paused' : 'running')) return PauseOutcome.confirmed;
      if (!await extensionAlive()) return PauseOutcome.notRunning;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return PauseOutcome.unconfirmed;
  }

  Future<void> _moduleOff() async {
    try {
      await injector.setModule(_module, null);
    } on SimInjectFailure {
      return;
    }
  }

  String get _linksFile => '${injector.controlDir}/links.json';

  /// Removes the short links once no app that may have cached one still runs; until then they stay (they point at the real folder, so they are harmless). True when they were kept.
  Future<bool> _retireLinks(String? appId) async {
    final holders = [
      for (final a in injector.loaded())
        if (appId != null && a.bundleId == appId) a.pid
    ];
    final links = Directory(shortRoot);
    if (holders.isEmpty) {
      if (links.existsSync()) links.deleteSync(recursive: true);
      final marker = File(_linksFile);
      if (marker.existsSync()) marker.deleteSync();
      return false;
    }
    if (links.existsSync()) File(_linksFile).writeAsStringSync(jsonEncode({'appId': appId, 'pids': holders}));
    return links.existsSync();
  }

  /// Removes kept short links once the apps that held them are gone (swept at each broadcast call, at glint startup and after a simulator shutdown).
  Future<void> sweepLinks() async {
    final marker = _readJson(_linksFile);
    if (marker == null) return;
    final pids = [for (final p in (marker['pids'] as List? ?? const [])) (p as num).toInt()];
    if ((await injector.processNames(pids)).isNotEmpty) return;
    final links = Directory(shortRoot);
    if (links.existsSync()) links.deleteSync(recursive: true);
    File(_linksFile).deleteSync();
  }

  Future<({ExtensionEnd end, bool linksKept})> _removeHostState(int? target, String? expected, String? appId) async {
    var end = ExtensionEnd.gone;
    if (target != null) end = await endExtension(target, expected);
    await ProcessRegistry.instance.stop('broadcast', device: injector.udid);
    await ProcessRegistry.instance.stop(_extensionPurpose, device: injector.udid);
    await stopScreen();
    final dir = Directory(_dir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final kept = await _retireLinks(appId);
    final claim = File('${injector.controlDir}/broadcast-claims/${injector.udid}.json');
    if (claim.existsSync()) claim.deleteSync();
    if (injector.activeModules().isEmpty) await injector.clearLaunchEnv();
    return (end: end, linksKept: kept);
  }

  /// Ends another glint's broadcast on this simulator: its extension process, its module config, its helpers' files and its claim.
  Future<ExtensionEnd> takeOver() async {
    final target = extensionPid();
    final expected = await expectedName();
    final appId = config()?['appId'] as String?;
    await _moduleOff();
    return (await _removeHostState(target, expected, appId)).end;
  }

  /// Undoes a start that failed halfway: the screen helper, the extension, the config and the claim.
  Future<void> abortStart() async {
    if (!_began) return;
    _aborted = true;
    await takeOver();
  }

  /// Removes what a glint that is gone left on this simulator, or with [ownedBy] what that glint owns; true when there was something.
  Future<bool> cleanOrphan({int? ownedBy}) async {
    await sweepLinks();
    final owner = (config()?['ownerPid'] as num?)?.toInt();
    if (owner == null) return false;
    if (ownedBy != null) {
      if (owner != ownedBy) return false;
    } else if (owner == pid || (await injector.processNames([owner])).containsKey(owner)) {
      return false;
    }
    await takeOver();
    return true;
  }

  /// Ends the run: the handler gets `broadcastFinished`, the host process exits, and everything glint made for it is removed except the short links an app may still hold. Confirms the extension process is gone.
  Future<StopResult> stop() async {
    final wasRunning = running;
    final before = config();
    final expected = await expectedName();
    final target = extensionPid();
    final last = report();
    await _moduleOff();
    final deadline = DateTime.now().add(_stopGrace);
    while ((running || (target != null && await _stateOfPid(target, expected) != PidState.gone)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final finalReport = report() ?? last;
    final log = logTail();
    final removed = await _removeHostState(target, expected, before?['appId'] as String?);
    _claims.release(injector.udid);
    return (
      report: finalReport,
      log: log,
      wasRunning: wasRunning,
      labels: {'video': (before?['video'] as Map?)?['label'], 'audio': (before?['audio'] as Map?)?['label']},
      extensionPid: target,
      end: removed.end == ExtensionEnd.gone && target != null && wasRunning ? ExtensionEnd.exited : removed.end,
      linksKept: removed.linksKept,
    );
  }
}

/// Removes the broadcast state of simulators whose owning glint is gone, or with [ownedBy] those that glint owns (its own exit), and short links nothing holds any more; never throws.
Future<void> sweepBroadcastState({int? ownedBy, String? home}) async {
  try {
    final root = Directory('${home ?? Platform.environment['HOME'] ?? '.'}/.glint/siminject');
    if (!root.existsSync()) return;
    for (final dir in root.listSync().whereType<Directory>()) {
      final udid = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final has = File('${dir.path}/modules/$_module.json').existsSync() || File('${dir.path}/links.json').existsSync();
      if (!has) continue;
      await SimBroadcast(SimInjector(udid, home: home)).cleanOrphan(ownedBy: ownedBy);
    }
  } on Object {
    return;
  }
}
