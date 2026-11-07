import 'dart:async';
import 'dart:math' show min;

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';

import '../../../observability.dart' show FlutterErrorEntry;

import '../../../interaction.dart';
import '../error_report.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// `hot_reload` reloads or restarts the attached app through the services its own `flutter run` registered, so no other project's app is ever touched.
class HotReloadTool extends GlintTool {
  const HotReloadTool();

  @override
  bool changesDevice(Map<String, Object?> args) => true;

  @override
  Tool get definition => Tool(
        name: 'hot_reload',
        description: 'Apply code changes to the attached app through its own `flutter run`: '
            'a hot reload keeps state, restart:true restarts it. Only the attached app is touched; '
            'never signal flutter_tools from a shell. Needs an app started by `flutter run`. '
            'Then watches the screen settle plus a few seconds and returns the errors the app threw meanwhile '
            '(data.errors: summary, location, count) and warns when a scrollable holds children but painted none; '
            '"0 errors" means the screen is healthy, not just that the code compiled.',
        inputSchema: ObjectSchema(
          properties: {
            'restart': Schema.bool(description: 'Hot restart instead of hot reload. Default false.'),
          },
        ),
      );

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) => const Duration(seconds: 150);

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final restart = argBool(request.arguments ?? const {}, 'restart') ?? false;
    final what = restart ? 'hot restart' : 'hot reload';
    if (GlintTool.pausedAtBreakpoint(session, 'a paused isolate cannot apply a $what') case final paused?) {
      return paused;
    }
    final runtime = session.runtime;
    final service = runtime.rawService;
    final isolateId = runtime.flutterIsolateId;
    final method = await _registeredMethod(service, restart ? 'hotRestart' : 'reloadSources');
    if (method == null) {
      return StructuredResponse.error(
        summary: 'no $what service on this app: it was not started by `flutter run`, or that `flutter run` has exited',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        nextSteps: const [
          'relaunch with attach launch:"<project root>" so glint owns the `flutter run`',
          'or ask the user to press r (reload) or R (restart) in their `flutter run` terminal',
        ],
      );
    }
    final watch = Stopwatch()..start();
    final app = session.active;
    final errorsBefore = app?.errors.lastSeq ?? 0;
    var phase = 'reloading';
    final heartbeat = _heartbeat(session, request, watch, () => '$what: $phase');
    try {
      try {
        await service.callMethod(method, isolateId: isolateId).timeout(const Duration(seconds: 90));
      } on RPCError catch (e) {
        return StructuredResponse.error(
          summary: '$what failed',
          errorKind: GlintErrorKind.backendToolError,
          detail: '${e.message}${e.details == null ? '' : ': ${e.details}'}',
          nextSteps: const ['fix the reported error (often a compile error), then call hot_reload again'],
        );
      } on TimeoutException {
        return StructuredResponse.error(
          summary: '$what did not finish within 90s',
          errorKind: GlintErrorKind.backendToolError,
          nextSteps: const ['call get_scene to see whether the app came back', 'check the `flutter run` output'],
        );
      }
      final reloadedMs = watch.elapsedMilliseconds;
      if (restart) await app?.followRestartedIsolate();
      final touches = restart && app != null && app.showTouches ? await app.setShowTouches(true) : null;
      phase = 'settling and watching for errors';
      await _awaitAfterglow(session);
      final errors = app?.errors.since(errorsBefore) ?? const <FlutterErrorEntry>[];
      app?.recheckViewports = true;
      final blankScrollables = await _blankScrollables(session);
      return StructuredResponse(
        summary: '$what done in ${reloadedMs}ms${touches?.on == true ? ' · touches shown' : ''}'
            ' · ${errorsHeadline(errors)}',
        warnings: [
          if (touches != null && touches.failed) 'touches are not shown after the restart: ${touches.detail}',
          for (final e in errors) errorWarning(e, errorsBefore),
          if (blankScrollables > 0) emptyViewportWarning(blankScrollables),
        ],
        nextSteps: errors.isEmpty && blankScrollables == 0
            ? const ['call get_scene to read the updated screen']
            : [
                if (errors.map((e) => e.location).whereType<String>().firstOrNull case final where?)
                  'open $where, fix the widget, then hot_reload again'
                else
                  'find the widget behind the error in the source, fix it, then hot_reload again',
                'call get_scene to see what is on screen',
              ],
        data: {
          'restart': restart,
          'elapsedMs': reloadedMs,
          'totalMs': watch.elapsedMilliseconds,
          'errors': [for (final e in errors) e.toJson(since: errorsBefore)],
          if (blankScrollables > 0) 'emptyViewports': blankScrollables,
          if (touches != null) 'touches': touches.toJson(),
        },
      );
    } finally {
      heartbeat?.cancel();
    }
  }

  /// How long errors are still collected after the screen settles.
  static const errorWindow = Duration(seconds: 3);

  /// Waits for the screen to settle, then the rest of [errorWindow]; a failed settle read only shortens the wait.
  Future<void> _awaitAfterglow(GlintSession session) async {
    final clock = Stopwatch()..start();
    try {
      await session.settleDetector.awaitSettle(
        ceilingMs: min(session.config.settleCeilingMs, 4000),
        quietFramesNeeded: session.config.settleQuietFrames,
      );
    } on Object {
      // the app may be mid-restart; the fixed window below still collects errors
    }
    final rest = errorWindow - clock.elapsed;
    if (!rest.isNegative) await Future<void>.delayed(rest);
  }

  Future<int> _blankScrollables(GlintSession session) async {
    final app = session.active;
    final runtime = app?.runtime;
    if (app == null || runtime == null || !runtime.isAttached) return 0;
    return await emptyViewportCount(runtime) ?? 0;
  }

  /// A progress notification every 15 s while the call blocks, so the client is never left blind.
  Timer? _heartbeat(GlintSession session, CallToolRequest request, Stopwatch clock, String Function() phase) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return Timer.periodic(const Duration(seconds: 15), (_) {
      notifier(ProgressNotification(
        progressToken: token,
        progress: clock.elapsed.inSeconds,
        total: 90,
        message: '${phase()} (${clock.elapsed.inSeconds}s)',
      ));
    });
  }

  /// Services `flutter run` registered on each VM connection, kept from the first subscription because the VM replays them only then.
  static final _registered = Expando<Map<String, String>>();

  /// The method name `flutter run` registered for [name] on this VM (e.g. `s0.hotRestart`), or null when none shows within a second.
  Future<String?> _registeredMethod(VmService service, String name) async {
    var known = _registered[service];
    if (known == null) {
      final map = _registered[service] = <String, String>{};
      known = map;
      service.onServiceEvent.listen((e) {
        final s = e.service;
        if (s == null) return;
        if (e.kind == EventKind.kServiceRegistered && e.method != null) map[s] = e.method!;
        if (e.kind == EventKind.kServiceUnregistered) map.remove(s);
      });
      try {
        await service.streamListen(EventStreams.kService);
      } on RPCError {
        // another listener subscribed first; its replay is not repeated
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (!known.containsKey(name) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return known[name];
  }
}
