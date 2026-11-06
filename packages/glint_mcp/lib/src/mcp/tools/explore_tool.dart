import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart' show GlintErrorKind;
import '../../../perception.dart' show suggestIds;
import '../envelope.dart';
import '../explore/graph.dart';
import '../explore/recorder.dart';
import '../explore/render.dart';
import '../session.dart';
import '../tool.dart';

/// Reads the persistent screen graph glint builds from every action and scene read: where the app has been, what was tried, what is left.
class ExploreTool extends GlintTool {
  const ExploreTool();

  @override
  Tool get definition => Tool(
        name: 'explore',
        description:
            'Ask the map of the app instead of remembering. glint records every screen you reach and every gesture you make into a per-app graph (kept on disk, survives restarts and context loss); this reads it. '
            'op: map (default: screens with visits, tried/total controls and stale marks, then edges `s1 --tap fab--> s2`), '
            'frontier (untried controls nearest first, each as the exact next call, plus stale screens to re-check), '
            'path (to:"<screen id or label>": the shortest known route from where you are, as a ready batch), '
            'reset (forget this app\'s graph). '
            'A screen is its route plus the set of stable glintIds on it (text and list rows ignored); a dialog or sheet is its own screen over the one it covers; a screen whose ids changed is stale until seen again. '
            'errorKind: sessionNotAttached, targetNotFound (path), invalidArgument.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'map (default) | frontier | path | reset'),
            'to': Schema.string(description: 'op=path: a screen id from map (s3) or its label or route.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'map';
    if (!const {'map', 'frontier', 'path', 'reset'}.contains(op)) {
      return StructuredResponse.error(
        summary: 'unknown op: $op',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['use map, frontier, path or reset'],
      );
    }
    final app = session.active;
    if (app == null || app.deviceMode) throw SessionNotAttachedError(missing: 'explore');
    final recorder = session.explore;
    if (op == 'reset') return _reset(recorder, app);
    if (op == 'path' && ((args['to'] as String?)?.trim().isEmpty ?? true)) {
      return StructuredResponse.error(
        summary: 'op=path needs to:',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['explore op:map lists the screens; pass an id like to:"s3" or its label'],
      );
    }
    final warning = await _refreshCurrent(session, app);
    final graph = recorder.graphFor(ExploreRecorder.keyOf(app));
    final here = recorder.current(app);
    final now = DateTime.now();
    return switch (op) {
      'frontier' => _frontier(graph, here, now, warning),
      'path' => _path(graph, here, (args['to'] as String).trim(), warning),
      _ => _map(graph, here, now, warning),
    };
  }

  /// Reads the screen once so the map knows where the app is now; a note when it could not.
  Future<String?> _refreshCurrent(GlintSession session, AppSession app) async {
    if (app.sceneMode == SceneMode.native) {
      return 'a native surface is in front of the app, so "here" is where the last read left it';
    }
    try {
      await session.withScene(
        (semantic) async => session.explore.noteScene(app, semantic),
        detail: SceneDetail.interactive,
      );
      return null;
    } on Object {
      return 'could not read the screen just now, so "here" is where the last read left it';
    }
  }

  StructuredResponse _map(ExploreGraph graph, ExploreScreen? here, DateTime now, String? warning) {
    if (graph.isEmpty) return _empty(graph, warning);
    final view = renderMap(graph, here, now);
    final untried = graph.screens.values.fold<int>(0, (n, s) => n + graph.untried(s).length);
    return StructuredResponse(
      summary: view.text,
      warnings: [if (warning != null) warning],
      nextSteps: [
        if (untried > 0) 'explore op:frontier lists the $untried untried controls nearest first',
        'explore op:path to:"<id>" gives the route to any screen above as a batch',
      ],
      data: view.data,
    );
  }

  StructuredResponse _frontier(ExploreGraph graph, ExploreScreen? here, DateTime now, String? warning) {
    if (graph.isEmpty) return _empty(graph, warning);
    final view = renderFrontier(graph, here, now);
    return StructuredResponse(
      summary: view.text,
      warnings: [if (warning != null) warning],
      nextSteps: [
        if (view.total > 0) 'run the first call, then explore op:frontier again; it shrinks as you go',
        if (view.total == 0) 'every control on the known screens was tried; navigate somewhere new and the map grows',
      ],
      data: view.data,
    );
  }

  StructuredResponse _path(ExploreGraph graph, ExploreScreen? here, String to, String? warning) {
    final matches = _resolve(graph, to);
    if (matches.isEmpty) {
      final names = [
        for (final s in graph.screens.values) ...[s.id, s.label, if (s.route.isNotEmpty) s.route]
      ];
      final near = {
        ...suggestIds(names, to, max: 4),
        ...names.where((n) => n.toLowerCase().contains(to.toLowerCase())).take(4),
      }.take(4).toList();
      return StructuredResponse.error(
        summary: 'no known screen "$to"',
        errorKind: GlintErrorKind.targetNotFound,
        detail: graph.isEmpty ? 'the map of ${graph.app} is empty' : '${graph.screens.length} screens are known',
        nextSteps: [
          if (near.isNotEmpty) 'closest: ${near.map((n) => '"$n"').join(', ')}',
          'explore op:map lists every screen id and label',
        ],
      );
    }
    final target = matches.first;
    if (here == null) {
      return StructuredResponse.error(
        summary: 'the map does not know which screen the app is on',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'no scene was read for ${graph.app} yet',
        nextSteps: const ['get_scene once, then explore op:path again'],
      );
    }
    final warnings = [
      if (warning != null) warning,
      if (matches.length > 1)
        '${matches.length} screens match "$to"; using ${target.id} (${matches.map((m) => m.id).join(', ')})',
      if (target.stale)
        '${target.id} is stale: its structure changed since it was last seen, so the route may differ now',
    ];
    if (target.id == here.id) {
      return StructuredResponse(
        summary: 'already on ${screenName(target)}',
        warnings: warnings,
        nextSteps: const ['explore op:frontier for what is left to try here'],
        data: {'from': here.id, 'to': target.id, 'steps': const <Object?>[]},
      );
    }
    final route = graph.paths(here.id)[target.id];
    if (route == null) {
      return StructuredResponse.error(
        summary: 'no known route from ${screenName(here)} to ${screenName(target)}',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'the map has no replayable chain of taps, long presses or back presses between them',
        nextSteps: [
          'explore op:frontier lists untried controls on ${here.id} that may lead there',
          'or navigate by hand; the edges you make are recorded',
        ],
      );
    }
    final steps = [
      for (final e in route) {'tool': e.tool, 'args': e.stepArgs}
    ];
    final batch = 'batch steps:${jsonEncode(steps)}';
    final lines = [
      '${screenName(here)} → ${screenName(target)}: ${route.length} step${route.length == 1 ? '' : 's'}',
      for (var i = 0; i < route.length; i++) ' ${i + 1}. ${route[i].call} → ${screenName(graph.screens[route[i].to]!)}',
    ];
    return StructuredResponse(
      summary: lines.join('\n'),
      warnings: warnings,
      nextSteps: [batch, 'if a step fails, get_scene and explore op:path again from where the app stopped'],
      data: {'from': here.id, 'to': target.id, 'steps': steps},
    );
  }

  List<ExploreScreen> _resolve(ExploreGraph graph, String to) {
    final q = to.toLowerCase();
    final byId = graph.screens[q];
    if (byId != null) return [byId];
    bool Function(ExploreScreen) test(bool Function(String) match) =>
        (s) => match(s.label.toLowerCase()) || match(s.route.toLowerCase());
    for (final match in <bool Function(String)>[(v) => v == q, (v) => v.contains(q)]) {
      final found = graph.screens.values.where(test(match)).toList()
        ..sort((a, b) {
          if (a.stale != b.stale) return a.stale ? 1 : -1;
          return b.visits.compareTo(a.visits);
        });
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  StructuredResponse _reset(ExploreRecorder recorder, AppSession app) {
    final dropped = recorder.reset(app);
    final name = ExploreRecorder.keyOf(app);
    return StructuredResponse(
      summary: dropped.screens == 0
          ? 'the map of $name was already empty'
          : 'forgot the map of $name: ${dropped.screens} screens, ${dropped.edges} edges (file removed)',
      nextSteps: const ['it starts again from the next scene read or action'],
      data: {'app': name, 'droppedScreens': dropped.screens, 'droppedEdges': dropped.edges},
    );
  }

  StructuredResponse _empty(ExploreGraph graph, String? warning) => StructuredResponse(
        summary: 'nothing recorded for ${graph.app} yet',
        warnings: [if (warning != null) warning],
        nextSteps: const ['get_scene and act as usual; every screen and gesture is recorded without calling explore'],
        data: {'app': graph.app, 'screenCount': 0, 'edgeCount': 0},
      );
}
