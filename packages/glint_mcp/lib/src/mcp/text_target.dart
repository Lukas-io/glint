import '../../interaction.dart' show GlintErrorKind;
import '../../perception.dart' show appBusyCause;
import '../../semantic.dart';
import 'envelope.dart';
import 'session.dart';
import 'tool_args.dart';

/// The id to act on from `glintId` or visible `text`, or the error to return; with awaitReady the text is waited for.
Future<({String? glintId, StructuredResponse? error})> readTarget(
    GlintSession session, Map<String, Object?> args, TargetedArgs t,
    {required String tool, String coordinates = ', or x + y'}) async {
  final glintId = args['glintId'] as String?;
  final text = args['text'] as String?;
  if (glintId != null && text != null) {
    return (
      glintId: null,
      error: StructuredResponse.error(
        summary: '$tool takes glintId or text, not both',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['drop text when you have the id'],
      ),
    );
  }
  if (glintId != null) return (glintId: glintId, error: null);
  if (text == null) {
    return (
      glintId: null,
      error: StructuredResponse.error(
        summary: '$tool needs glintId or text$coordinates',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass glintId from get_scene, or the visible text as text'],
      ),
    );
  }
  return resolveTextTarget(session, text, tool: tool, waitMs: t.awaitReady ? t.readyTimeoutMs : 0);
}

/// One node whose visible text matched, and the id an action on it should hit.
typedef TextMatch = ({String glintId, String label, Inert? inert});

/// The glintId behind visible [text], or the error to return: exact matches (case-insensitive) win over contains; the top overlay is searched before the screen. With [waitMs] the scene is re-read until the text appears or the time runs out.
Future<({String? glintId, StructuredResponse? error})> resolveTextTarget(GlintSession session, String text,
    {required String tool, int waitMs = 0}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: waitMs));
  while (true) {
    final List<TextMatch> matches;
    final List<String> visible;
    try {
      (matches, visible) = await session.withScene(
        (scene) async => (textMatches(scene, text), visibleLabels(scene)),
        detail: SceneDetail.interactive,
      );
    } on Object catch (e) {
      final busy = appBusyCause(e);
      if (busy == null || waitMs == 0) rethrow;
      if (!DateTime.now().isBefore(deadline)) {
        return (glintId: null, error: StructuredResponse.appBusy(busy.timeout, summary: '$tool: the app stayed busy'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      continue;
    }
    final usable = matches.where((m) => m.inert == null).toList();
    if (usable.length == 1) return (glintId: usable.single.glintId, error: null);
    if (usable.isEmpty && matches.isNotEmpty) return (glintId: null, error: _inertTarget(tool, text, matches.first));
    if (matches.length > 1) {
      return (
        glintId: null,
        error: StructuredResponse.error(
          summary: '$tool: ${matches.length} targets show "$text"',
          errorKind: GlintErrorKind.invalidArgument,
          detail: matches.map((m) => '${m.glintId} "${m.label}"').join('\n'),
          nextSteps: [
            'pass glintId with one of: ${matches.map((m) => m.glintId).join(', ')}',
            'or pass the full text of the one you want',
          ],
        ),
      );
    }
    if (!DateTime.now().isBefore(deadline)) {
      return (
        glintId: null,
        error: StructuredResponse.error(
          summary: '$tool: no visible text matches "$text"',
          errorKind: waitMs > 0 ? GlintErrorKind.targetNeverReady : GlintErrorKind.unresolvedTarget,
          detail:
              visible.isEmpty ? 'the screen shows no text' : 'text on screen: ${visible.map((t) => '"$t"').join(', ')}',
          nextSteps: const [
            'scroll_to_find text:<text> tap:true when it is further down a list',
            'get_scene to read the screen',
          ],
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

/// Matches for [text] in the top overlay, else the screen; the target is the nearest tappable ancestor of the matching node, or the node itself.
List<TextMatch> textMatches(SemanticScene scene, String text) {
  final want = _norm(text);
  if (want.isEmpty) return const [];
  final layers = [
    for (final layer in scene.overlayLayers.reversed) layer.nodes,
    [scene.root],
  ];
  for (final roots in layers) {
    final exact = <TextMatch>[];
    final partial = <TextMatch>[];
    void visit(SemanticNode n, SemanticNode? tappable) {
      final here = n.glintId != null && n.affordances.contains(Affordance.tappable) ? n : tappable;
      final label = _label(n);
      final target = here ?? (n.glintId != null ? n : null);
      if (label != null && target != null) {
        final have = _norm(label);
        final match = (glintId: target.glintId!, label: label, inert: target.inert ?? n.inert);
        if (have == want) {
          exact.add(match);
        } else if (have.contains(want)) {
          partial.add(match);
        }
      }
      for (final c in n.children) {
        visit(c, here);
      }
    }

    for (final r in roots) {
      visit(r, null);
    }
    final found = _distinct(exact.isNotEmpty ? exact : partial);
    if (found.isNotEmpty) return found;
  }
  return const [];
}

/// Why the only control showing [text] cannot be used right now, and what usually brings it back.
StructuredResponse _inertTarget(String tool, String text, TextMatch m) => m.inert == Inert.hidden
    ? StructuredResponse.error(
        summary:
            '$tool: "$text" (${m.glintId}) is hidden: it is faded out to opacity 0, so a person cannot see or tap it',
        errorKind: GlintErrorKind.notHittable,
        nextSteps: const [
          'controls that fade out (video, call and camera screens) come back after a tap on the screen: '
              'tap an empty area, then retry',
          'get_scene shows it without [hidden] once it is back',
        ],
      )
    : StructuredResponse.error(
        summary: '$tool: "$text" (${m.glintId}) ignores touches right now (it sits under an active '
            'IgnorePointer or AbsorbPointer)',
        errorKind: GlintErrorKind.notHittable,
        nextSteps: const [
          'the screen is usually busy or waiting on a step first: get_scene, do what it asks, then retry',
        ],
      );

/// Up to 12 distinct labels on screen, for the not-found detail.
List<String> visibleLabels(SemanticScene scene) {
  final out = <String>[];
  final roots = [for (final l in scene.overlayLayers) ...l.nodes, scene.root];
  for (final r in roots) {
    for (final n in r.walk()) {
      final l = _label(n)?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (l == null || l.isEmpty || out.contains(l)) continue;
      out.add(l.length > 40 ? '${l.substring(0, 39)}…' : l);
      if (out.length >= 12) return out;
    }
  }
  return out;
}

String? _label(SemanticNode n) => switch (n) {
      SemanticButton(:final label) => label,
      SemanticText(:final content) => content,
      SemanticInput(:final hint) => hint,
      SemanticAppBar(:final title) => title,
      _ => null,
    };

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

List<TextMatch> _distinct(List<TextMatch> matches) {
  final seen = <String>{};
  return [
    for (final m in matches)
      if (seen.add(m.glintId)) m
  ];
}
