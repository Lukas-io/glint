import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../media/host_tools.dart';
import 'bounded_process.dart';
import 'result.dart';
import 'siminject_download.dart';
import 'siminject_locator.dart';

/// How the injected library came to be in an app, in the order glint prefers.
enum InjectLoad { already, launch, lateLoad, relaunch }

/// One app process that has the injected library loaded, as its ready file reports it.
class InjectedApp {
  const InjectedApp({
    required this.pid,
    required this.bundleId,
    required this.protocol,
    required this.modules,
    required this.active,
    this.foreground = false,
  });

  final int pid;
  final String bundleId;
  final int protocol;
  final List<String> modules;
  final List<String> active;

  /// Whether the app was in front when it last reported.
  final bool foreground;

  Map<String, Object?> toJson() => {'pid': pid, 'bundleId': bundleId, 'modules': modules, 'active': active};
}

/// A user app running on the simulator.
typedef RunningApp = ({int pid, String bundleId});

/// What [SimInjector.ensure] did, in the shape every injecting feature returns as `injected`.
class InjectReport {
  const InjectReport({
    required this.load,
    required this.apps,
    required this.waiting,
    required this.relaunched,
    this.olderLibrary = const [],
    this.notLoaded = const [],
    this.target,
    this.running = const [],
  });

  final InjectLoad load;
  final List<InjectedApp> apps;
  final List<String> waiting;
  final List<String> relaunched;

  /// Other running apps holding a copy of the library that lacks the module; glint left them alone.
  final List<String> olderLibrary;

  /// Other running apps glint could not load into; they run without it.
  final List<String> notLoaded;

  /// The app a command should go to: the attached one, else the one in front, else the only running app.
  final String? target;

  /// Every user app running when the library was loaded.
  final List<String> running;

  /// Warnings naming [olderLibrary] and [notLoaded], or none.
  List<String> get warnings => [
        if (olderLibrary.isNotEmpty)
          '${olderLibrary.join(', ')} holds an older glint library without this feature and was left alone (restart it to load the current one)',
        if (notLoaded.isNotEmpty) 'glint could not load into ${notLoaded.join(', ')}, which keeps running without it',
      ];

  Map<String, Object?> toJson({required List<String> modules}) => {
        'modules': modules,
        'loaded': load.name,
        'apps': [for (final a in apps) a.bundleId],
        if (waiting.isNotEmpty) 'waitingForLaunch': waiting,
        if (relaunched.isNotEmpty) 'relaunched': relaunched,
        if (olderLibrary.isNotEmpty) 'olderLibrary': olderLibrary,
        if (notLoaded.isNotEmpty) 'notLoaded': notLoaded,
      };
}

/// Why injection failed: a branchable [kind], the reason in [detail] and what to do next.
class SimInjectFailure implements Exception {
  SimInjectFailure(this.kind, this.message, this.detail, this.nextSteps);

  final GlintErrorKind kind;
  final String message;
  final String detail;
  final List<String> nextSteps;

  @override
  String toString() => 'SimInjectFailure: $message ($detail)';
}

/// Loads glint's injectable library into simulator apps and talks to its feature modules, for every feature that needs code running inside the app process.
class SimInjector {
  SimInjector(this.udid, {String? home, this.progress}) : _home = home ?? Platform.environment['HOME'] ?? '.';

  final String udid;
  final PhaseReporter? progress;
  final String _home;
  String? _dylib;

  static const _launchEnv = 'DYLD_INSERT_LIBRARIES';

  /// The per-device control directory the library and glint share.
  String get controlDir => controlDirOf(udid);

  /// The control directory of the simulator [udid].
  String controlDirOf(String udid) => '$_home/.glint/siminject/$udid';

  /// Creates the control directories readable by this user only.
  void prepareControlDir() {
    for (final path in ['$_home/.glint/siminject', controlDir]) {
      Directory(path).createSync(recursive: true);
      Process.runSync('chmod', ['700', path]);
    }
  }

  Future<HostRun> _simctl(List<String> args, {Duration timeout = const Duration(seconds: 90), String? phase}) async {
    final r = await runBounded('xcrun', ['simctl', ...args], timeout: timeout, phase: phase);
    return HostRun(r.exitCode, utf8.encode('${r.stdout}'), '${r.stderr}');
  }

  /// User apps running now (Apple's own and glint's test runners left out).
  Future<List<RunningApp>> runningApps() async {
    final r = await _simctl(['spawn', udid, 'launchctl', 'list']);
    final apps = <RunningApp>[];
    for (final line in r.text.split('\n')) {
      final match = RegExp(r'^\s*(\d+)\s+\S+\s+UIKitApplication:([^\[\s]+)\[').firstMatch(line);
      if (match == null) continue;
      final id = match.group(2)!;
      if (id.startsWith('com.apple.') || id.toLowerCase().contains('xctrunner')) continue;
      apps.add((pid: int.parse(match.group(1)!), bundleId: id));
    }
    return apps;
  }

  /// Apps that report the library loaded and are still alive.
  List<InjectedApp> loaded() {
    final dir = Directory('$controlDir/ready');
    if (!dir.existsSync()) return const [];
    final entries = <(File, Map<String, Object?>)>[];
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        entries.add((f, jsonDecode(f.readAsStringSync()) as Map<String, Object?>));
      } on Object {
        continue;
      }
    }
    final alive = _livePids([
      for (final e in entries)
        if (e.$2['pid'] is int) e.$2['pid'] as int
    ]);
    final apps = <InjectedApp>[];
    for (final (file, j) in entries) {
      final pid = j['pid'];
      if (pid is! int) continue;
      if (!alive.contains(pid)) {
        file.deleteSync();
        continue;
      }
      apps.add(InjectedApp(
        pid: pid,
        bundleId: (j['bundleId'] as String?) ?? '',
        protocol: (j['protocol'] as int?) ?? 0,
        modules: ((j['modules'] as List?) ?? const []).cast<String>(),
        active: ((j['active'] as List?) ?? const []).cast<String>(),
        foreground: j['foreground'] == true,
      ));
    }
    return apps;
  }

  /// Which of [pids] are running, from one `ps` call.
  Set<int> _livePids(List<int> pids) {
    if (pids.isEmpty) return const {};
    final r = Process.runSync('ps', ['-o', 'pid=,comm=', '-p', pids.join(',')]);
    return parseProcessNames('${r.stdout}').keys.toSet();
  }

  /// The executable path of each of [pids] that is running, from one bounded `ps` call (a simulator process is a Mac process with the same pid).
  Future<Map<int, String>> processNames(Iterable<int> pids) async {
    final list = pids.toSet().toList();
    if (list.isEmpty) return const {};
    final r = await runBounded('ps', ['-o', 'pid=,comm=', '-p', list.join(',')],
        timeout: const Duration(seconds: 10), phase: 'checking which processes are running');
    return parseProcessNames('${r.stdout}');
  }

  /// Reads `pid command` lines from `ps -o pid=,comm=`.
  static Map<int, String> parseProcessNames(String text) {
    final names = <int, String>{};
    for (final line in text.split('\n')) {
      final match = RegExp(r'^\s*(\d+)\s+(.*\S)\s*$').firstMatch(line);
      if (match != null) names[int.parse(match.group(1)!)] = match.group(2)!;
    }
    return names;
  }

  /// The library's path, found, downloaded or compiled, and checked to be signed so dyld never aborts an app launch on it.
  Future<String> dylibPath() async {
    final known = _dylib;
    if (known != null) return known;
    try {
      final path = await ensureSimInject(phases: progress);
      if (await _signed(path)) return _dylib = path;
      File(path).deleteSync();
      final rebuilt = await ensureSimInject(phases: progress);
      if (await _signed(rebuilt)) return _dylib = rebuilt;
      throw SimInjectFailure(
          GlintErrorKind.unsupportedToolchain,
          'the glint simulator library is not validly signed',
          rebuilt,
          ['remove ~/.glint/bin/glint-siminject-*.dylib and repeat the call', 'check Xcode command line tools']);
    } on SimInjectError catch (e) {
      throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, e.message, e.detail, e.nextSteps);
    }
  }

  Future<bool> _signed(String path) async {
    final r = await runBounded('codesign', ['-v', path],
        timeout: const Duration(seconds: 20), phase: 'checking the library signature');
    return r.exitCode == 0;
  }

  /// Makes every app the simulator launches from now on load the library (it stays dormant until a module is turned on).
  Future<void> setLaunchEnv(String dylib) async {
    final r = await _simctl(['spawn', udid, 'launchctl', 'setenv', _launchEnv, dylib]);
    if (!r.ok) {
      throw SimInjectFailure(GlintErrorKind.backendToolError, 'could not set the launch environment on $udid',
          r.errTail(), ['check the simulator is booted (xcrun simctl list devices booted), then retry']);
    }
  }

  /// Stops the simulator loading the library into apps it launches next.
  Future<void> clearLaunchEnv() async {
    await _simctl(['spawn', udid, 'launchctl', 'unsetenv', _launchEnv]);
  }

  /// Gets the library into [appId] (or into every running user app when null): already loaded, loaded at its next launch, loaded into the running process with lldb, or, when [relaunch] allows, by restarting it. With a [module], only the target (the [appId], else the app in front, else the only running app) must succeed and an older copy there is refused; another app that cannot take it is named in the report and left running.
  Future<InjectReport> ensure({String? appId, bool relaunch = false, String? module}) async {
    final dylib = await dylibPath();
    await setLaunchEnv(dylib);
    final running = await runningApps();
    final names = [for (final a in running) a.bundleId];
    final targets = [
      for (final app in running)
        if (appId == null || app.bundleId == appId) app,
    ];
    if (appId != null && targets.isEmpty) {
      return InjectReport(load: InjectLoad.launch, apps: loaded(), waiting: [appId], relaunched: const []);
    }
    var target = appId != null ? targets.first : (module == null ? null : await _frontApp(running));
    bool strict(RunningApp app) => module == null || appId != null || app == target;
    final have = {for (final a in loaded()) a.pid: a};
    final missing = [
      for (final t in targets)
        if (!have.containsKey(t.pid)) t,
    ];
    final stale = [
      for (final t in targets)
        if (have[t.pid] != null && _staleReason(have[t.pid]!, module) != null) t,
    ];
    final olderLibrary = <String>[];
    final notLoaded = <String>[];
    final relaunched = <String>[];
    var load = missing.isEmpty && stale.isEmpty ? InjectLoad.already : InjectLoad.lateLoad;
    for (final app in [...missing, ...stale]) {
      final isStale = stale.contains(app);
      final why = isStale ? _staleReason(have[app.pid]!, module)! : await _lateLoad(app, dylib);
      if (why == null) continue;
      if (!strict(app)) {
        (isStale ? olderLibrary : notLoaded).add(app.bundleId);
        continue;
      }
      if (!relaunch) throw _relaunchRequired(app, why);
      await _relaunch(app);
      relaunched.add(app.bundleId);
      load = InjectLoad.relaunch;
    }
    if (targets.isEmpty) load = InjectLoad.launch;
    if (module != null && appId == null && target == null) target = await _frontApp(running);
    final held = {for (final a in loaded()) a.pid};
    if (targets.isNotEmpty && !targets.any((t) => held.contains(t.pid) || relaunched.contains(t.bundleId))) {
      throw SimInjectFailure(
        GlintErrorKind.unsupportedBackendAction,
        'glint could not be loaded into any running app',
        'running: ${names.join(', ')}',
        [
          'pass appId:"<bundle id>" with relaunch:true to restart one app so glint loads before it starts',
          'or attach launch:"<bundle id>"',
        ],
      );
    }
    return InjectReport(
      load: load,
      apps: loaded(),
      waiting: const [],
      relaunched: relaunched,
      olderLibrary: olderLibrary,
      notLoaded: notLoaded,
      target: target?.bundleId,
      running: names,
    );
  }

  /// The running app whose library says it is in front, else the only running app, else null.
  Future<RunningApp?> _frontApp(List<RunningApp> running) async {
    if (running.isEmpty) return null;
    if (loaded().isNotEmpty) {
      await notify('glint.siminject.ping');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final front = loaded().where((a) => a.foreground).map((a) => a.pid).toSet();
      final found = running.where((r) => front.contains(r.pid)).firstOrNull;
      if (found != null) return found;
    }
    return running.length == 1 ? running.first : null;
  }

  /// Why the copy of the library an app already holds cannot serve [module], or null when it can.
  String? _staleReason(InjectedApp app, String? module) {
    if (app.protocol != siminjectProtocol) {
      return 'its loaded copy speaks an older protocol than this glint (needs $siminjectProtocol)';
    }
    if (module != null && !app.modules.contains(module)) {
      return 'its loaded copy of the glint library has no `$module` module (an older glint loaded it)';
    }
    return null;
  }

  SimInjectFailure _relaunchRequired(RunningApp app, String why) => SimInjectFailure(
        GlintErrorKind.unsupportedBackendAction,
        '${app.bundleId} started before glint could load into it',
        why,
        [
          'repeat the call with relaunch:true to restart ${app.bundleId} (its state is lost and the VM connection drops)',
          'or kill_app, then attach launch:"${app.bundleId}"',
        ],
      );

  /// Whether a debugger may attach without macOS asking for an administrator.
  Future<bool> _debuggerPromptFree() async {
    final status = await runBounded('DevToolsSecurity', ['-status'],
        timeout: const Duration(seconds: 10), phase: 'checking the Developer Tools permission');
    if ('${status.stdout}'.toLowerCase().contains('enabled') &&
        !'${status.stdout}'.toLowerCase().contains('disabled')) {
      return true;
    }
    final groups = await runBounded('id', ['-Gn'], timeout: const Duration(seconds: 10), phase: 'checking user groups');
    return '${groups.stdout}'.split(RegExp(r'\s+')).contains('_developer');
  }

  /// Loads the library into the running [app] with lldb; null on success, else why it could not.
  Future<String?> _lateLoad(RunningApp app, String dylib) async {
    final lldb = findHostBinary('lldb');
    if (lldb == null) return 'lldb is not installed, so glint cannot load into a running app';
    if (!await _debuggerPromptFree()) {
      return 'attaching a debugger needs the Developer Tools permission, which would raise an administrator dialog, so glint skipped it';
    }
    final run = await runBounded(lldb, ['-b', '-p', '${app.pid}', '-o', 'process load $dylib', '-o', 'detach'],
        timeout: const Duration(seconds: 120), phase: 'loading glint into ${app.bundleId} (pid ${app.pid})');
    if (run.exitCode != 0 && !'${run.stdout}'.contains('Image 0 loaded')) {
      return 'lldb could not load into the running process';
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (loaded().any((a) => a.pid == app.pid && a.protocol == siminjectProtocol)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return 'the library loaded but did not report ready';
  }

  Future<void> _relaunch(RunningApp app) async {
    Future<void> body() async {
      await _simctl(['terminate', udid, app.bundleId]);
      final launch = await _simctl(['launch', udid, app.bundleId]);
      if (!launch.ok) {
        throw SimInjectFailure(GlintErrorKind.backendToolError, 'could not start ${app.bundleId} again',
            launch.errTail(), ['attach launch:"${app.bundleId}"']);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (loaded().any((a) => a.bundleId == app.bundleId && a.pid != app.pid)) return;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      throw SimInjectFailure(
          GlintErrorKind.backendToolError,
          '${app.bundleId} started but did not load glint',
          'no ready file appeared within 30 s',
          ['check the app runs on this simulator (attach), then repeat the call']);
    }

    await (progress?.during('restarting ${app.bundleId} so glint loads into it', body) ?? body());
  }

  /// Turns [module] on with [config], or off when [config] is null, and tells every loaded app.
  Future<void> setModule(String module, Map<String, Object?>? config) async {
    prepareControlDir();
    final file = File('$controlDir/modules/$module.json');
    if (config == null) {
      if (file.existsSync()) file.deleteSync();
    } else {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(config));
      tmp.renameSync(file.path);
    }
    await notify('glint.siminject.$module');
  }

  /// Turns [module] on with no command and a new epoch, so no earlier command can replay, after deleting status files of dead processes; false when it was already on.
  Future<bool> enableModule(String module) async {
    if (moduleConfig(module) != null) return false;
    pruneStatuses(module);
    final epoch =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 32).toRadixString(36)}';
    await setModule(module, {'epoch': epoch, 'seq': 0});
    return true;
  }

  /// The pids of the apps whose ready file says they are alive.
  Set<int> livePids() => {for (final a in loaded()) a.pid};

  /// The status files a module's apps write, as file names.
  Set<String> statusFiles(String module) {
    final dir = Directory('$controlDir/events');
    if (!dir.existsSync()) return const {};
    return {
      for (final f in dir.listSync().whereType<File>())
        if (RegExp('/$module-\\d+\\.json\$').hasMatch(f.path)) f.uri.pathSegments.last,
    };
  }

  /// What the apps among [alive] report in their [module] status files; nothing is deleted.
  List<Map<String, Object?>> readStatuses(String module, {required Set<int> alive}) {
    final reports = <Map<String, Object?>>[];
    for (final name in statusFiles(module)) {
      try {
        final j = jsonDecode(File('$controlDir/events/$name').readAsStringSync()) as Map<String, Object?>;
        if (alive.contains(j['pid'])) reports.add(j);
      } on Object {
        continue;
      }
    }
    return reports;
  }

  /// Deletes the [module] status files of processes that are gone.
  void pruneStatuses(String module) {
    final alive = livePids();
    for (final name in statusFiles(module)) {
      final file = File('$controlDir/events/$name');
      try {
        final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        if (!alive.contains(j['pid'])) file.deleteSync();
      } on Object {
        continue;
      }
    }
  }

  /// Turns [module] off, waits for its apps to stop reporting in front, removes what glint left for it and, when no module is left, the launch environment; true when it was on.
  Future<bool> stopModule(String module) async {
    final was = moduleConfig(module) != null;
    await setModule(module, null);
    final alive = livePids();
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (
        DateTime.now().isBefore(deadline) && readStatuses(module, alive: alive).any((j) => j['foreground'] == true)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    for (final name in statusFiles(module)) {
      File('$controlDir/events/$name').deleteSync();
    }
    for (final name in const ['events', 'modules']) {
      final dir = Directory('$controlDir/$name');
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    }
    if (activeModules().isEmpty) await clearLaunchEnv();
    return was;
  }

  /// The config [module] runs with, or null when it is off.
  Map<String, Object?>? moduleConfig(String module) {
    final file = File('$controlDir/modules/$module.json');
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    } on Object {
      return null;
    }
  }

  /// Modules that are on.
  List<String> activeModules() {
    final dir = Directory('$controlDir/modules');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
        f.uri.pathSegments.last.replaceFirst('.json', ''),
    ];
  }

  /// Posts a Darwin notification inside the simulator.
  Future<void> notify(String name) async {
    final r = await _simctl(['notify_post', udid, name]);
    if (!r.ok) {
      throw SimInjectFailure(GlintErrorKind.backendToolError, 'could not signal the simulator', r.errTail(),
          ['check the simulator is booted, then retry']);
    }
  }
}
