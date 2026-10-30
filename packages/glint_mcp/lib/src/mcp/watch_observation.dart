import '../../semantic.dart';
import 'text_target.dart';

/// What one scene read showed, reduced to what watch conditions compare between ticks.
class WatchObservation {
  WatchObservation({
    this.route = '',
    this.overlay = false,
    this.overlayKind,
    this.labels = const {},
    this.tappableIds = const {},
    this.textShown = const {},
    this.idShown = const {},
  });

  static const _labelLimit = 60;
  static const appearedCap = 10;

  final String route;
  final bool overlay;

  /// `dialog` / `bottomSheet` for an in-app layer, `system surface "<name>"` for a native one.
  final String? overlayKind;
  final Set<String> labels;
  final Set<String> tappableIds;
  final Map<String, bool> textShown;
  final Map<String, bool> idShown;

  /// Reads [scene], answering `texts` the way `wait_for` matches them and `ids` by glintId.
  factory WatchObservation.read(SemanticScene scene, {required Set<String> texts, required Set<String> ids}) {
    final labels = <String>{};
    final tappable = <String>{};
    for (final n in scene.allNodes()) {
      if (n.inert == Inert.hidden) continue;
      final label = nodeLabel(n)?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (label != null && label.isNotEmpty) {
        labels.add(label.length > _labelLimit ? '${label.substring(0, _labelLimit - 1)}…' : label);
      }
      if (n.glintId != null && n.affordances.contains(Affordance.tappable)) tappable.add(n.glintId!);
    }
    return WatchObservation(
      route: scene.routeStack.isEmpty ? '' : scene.routeStack.first.name,
      overlay: scene.overlayLayers.isNotEmpty,
      overlayKind: scene.overlayLayers.isEmpty ? null : scene.overlayLayers.first.kind,
      labels: labels,
      tappableIds: tappable,
      textShown: {
        for (final t in texts) t: textMatches(scene, t).any((m) => m.inert != Inert.hidden),
      },
      idShown: {for (final id in ids) id: scene.sourceScene.findByGlintId(id) != null},
    );
  }

  /// This observation with a native surface in front: the in-app answers are kept from before, since the Flutter tree cannot be read.
  WatchObservation withSurface(String name) => WatchObservation(
        route: route,
        overlay: true,
        overlayKind: 'system surface "$name"',
        labels: labels,
        tappableIds: tappableIds,
        textShown: textShown,
        idShown: idShown,
      );

  /// Texts and tappable ids on screen now that [previous] did not show, each capped, with how many were left out.
  ({List<String> texts, List<String> ids, int more}) appearedSince(WatchObservation? previous) {
    if (previous == null) return (texts: const [], ids: const [], more: 0);
    final texts = labels.difference(previous.labels).toList();
    final ids = tappableIds.difference(previous.tappableIds).toList();
    final more = (texts.length > appearedCap ? texts.length - appearedCap : 0) +
        (ids.length > appearedCap ? ids.length - appearedCap : 0);
    return (
      texts: texts.take(appearedCap).toList(),
      ids: ids.take(appearedCap).toList(),
      more: more,
    );
  }
}
