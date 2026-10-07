import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// `hot_reload` reloads or restarts the attached app through the services its own `flutter run` registered, so no other project's app is ever touched.
class HotReloadTool extends GlintTool {
  const HotReloadTool();

  @override
  Tool get definition => Tool(
        name: 'hot_reload',
        description: 'Apply code changes to the attached app through its own `flutter run`: '
            'a hot reload keeps state, restart:true restarts it. Only the attached app is touched; '
            'never signal flutter_tools from a shell. Needs an app started by `flutter run`.',
        inputSchema: ObjectSchema(
          properties: {
            'restart': Schema.bool(description: 'Hot restart instead of hot reload. Default false.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final restart = argBool(request.arguments ?? const {}, 'restart') ?? false;
    final what = restart ? 'hot restart' : 'hot reload';
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
    return StructuredResponse(
      summary: '$what done in ${watch.elapsedMilliseconds}ms',
      nextSteps: const ['call get_scene to read the updated screen'],
      data: {'restart': restart, 'elapsedMs': watch.elapsedMilliseconds},
    );
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
