import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';
import 'scroll_tool.dart';
import 'tap_tool.dart';

/// What one read of the target means for the scroll loop.
enum FindVerdict { found, covered, keepScrolling }

/// A lookup needs the target painted on the viewport; a tap needs it hittable there, and a painted one that is not is covered.
FindVerdict findVerdict(ResolvedCoord coord, {required bool tap}) {
  if (!coord.centerOnViewport) return FindVerdict.keepScrolling;
  if (tap ? coord.hittable : coord.painted) return FindVerdict.found;
  return tap && coord.painted ? FindVerdict.covered : FindVerdict.keepScrolling;
}

/// Loops `get_scene` + `scroll` until a target (glintId or text content)
/// is on screen (and hittable for tap:true), or the ceiling is reached. Stops early if already visible.
class ScrollToFindTool extends GlintTool {
  const ScrollToFindTool();

  @override
  Tool get definition => Tool(
        name: 'scroll_to_find',
        description:
            'Scroll until a target is on screen, then return its glintId (tap:true also taps it, so it must also be hittable). Match targetGlintId (exact id) or targetTextContent (substring of any text), not both. direction default down, maxScrolls 8, amountFraction 0.6. errorKind: targetNotFound (never appeared), scrollLimitReached (appeared, never on screen), notHittable (tap:true, on screen but covered), unresolvedTarget (inside a modal, not scrollable content), flutterModeRequired (device mode).',
        inputSchema: ObjectSchema(
          properties: {
            'targetGlintId': Schema.string(
              description: 'Stable id to find. Mutually exclusive with `targetTextContent`.',
            ),
            'targetTextContent': Schema.string(
              description: 'Case-insensitive substring to match against any text '
                  'node\'s content. Useful when the compact renderer collapsed '
                  'the id you wanted.',
            ),
            'text': Schema.string(
              description: 'Alias of targetTextContent.',
            ),
            'direction': Schema.string(
              description: 'One of: up, down, left, right. Default down.',
            ),
            'maxScrolls': Schema.int(
              description: 'Attempt ceiling. Default 8.',
            ),
            'amountFraction': Schema.num(
              description: 'Scroll size per step. Default 0.6.',
            ),
            'tap': Schema.bool(
              description:
                  'Tap it once found (its nearest tappable ancestor when the match is text) and return the tap result. Default false.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final targetGlintId = args['targetGlintId'] as String?;
    final targetText = (args['targetTextContent'] as String?) ?? (args['text'] as String?);
    final dirName = (args['direction'] as String?) ?? 'down';
    final maxScrolls = argInt(args, 'maxScrolls') ?? session.config.scrollMaxScrolls;
    final amount = (argNum(args, 'amountFraction') ?? session.config.scrollAmountFraction).toDouble();
    final tap = argBool(args, 'tap') ?? false;

    if ((targetGlintId == null) == (targetText == null)) {
      return StructuredResponse.error(
        summary: 'exactly one of targetGlintId or targetTextContent is required',
        errorKind: GlintErrorKind.invalidArgument,
      );
    }

    final dir = enumByName(ScrollDirection.values, dirName);
    if (dir == null) {
      return StructuredResponse.error(
        summary: 'unknown scroll direction: $dirName',
        errorKind: GlintErrorKind.invalidArgument,
      );
    }

    final scrollArgs = CallToolRequest(name: 'scroll', arguments: {
      'direction': dir.name,
      'amountFraction': amount,
    });
    final scroller = const ScrollTool();
    final criterion = targetGlintId != null ? 'glintId=$targetGlintId' : 'text~"$targetText"';

    var seenInTree = false; // target appeared in scene at least once
    var seenInOverlay = false; // target found in overlay (not in scrollable content)
    var lastTexts = const <String>[];
    var lastIds = const <String>[];
    ResolvedCoord? covered; // on screen but covered (tap only)
    int? coveredAt; // the attempt that first saw it covered
    var last = 0;

    String? tapId;
    StructuredResponse? foundReply;
    for (var i = 0; i <= maxScrolls; i++) {
      last = i;
      final scene = await session.reader.readSummary();
      try {
        lastTexts = _visibleTexts(scene.root);
        lastIds = scene.glintIds;
        final hit = targetGlintId != null ? scene.findByGlintId(targetGlintId) : _findTextNode(scene.root, targetText!);
        if (hit != null && hit.glintId != null) {
          seenInTree = true;
          // Check if it's in the overlay layer rather than the scrollable base.
          if (targetGlintId != null && scene.isInOverlay(targetGlintId)) {
            seenInOverlay = true;
          }
          try {
            final coord = await session.resolver.resolve(scene, hit.glintId!);
            // On-viewport is required: a hittable-but-scrolled-out target
            // would send the agent straight back into an offViewport refusal.
            final verdict = findVerdict(coord, tap: tap);
            if (verdict == FindVerdict.covered) {
              covered = coord;
              coveredAt ??= i;
            }
            if (verdict == FindVerdict.found) {
              final found = StructuredResponse(
                summary: 'found $criterion after $i scroll(s)',
                data: {
                  'attempts': i,
                  'glintId': hit.glintId,
                  'hittable': coord.hittable,
                  'painted': coord.painted,
                  if (hit.textPreview != null) 'matchedText': hit.textPreview,
                },
              );
              if (!tap) {
                return coord.hittable
                    ? found
                    : found.addWarnings(['a tap at its centre would land on ${_cover(coord)}']);
              }
              tapId = tapTargetFor([scene.root, ...scene.overlayRoots], hit) ?? hit.glintId;
              foundReply = found;
              break;
            }
          } on Exception {
            // resolve can fail mid-scroll if the node was just replaced;
            // fall through and try another scroll.
          }
        }
      } finally {
        await scene.dispose();
      }

      // A covered target gets one more scroll (a bar along the edge may hide it), then the search stops.
      if (tapId != null || i == maxScrolls || (coveredAt != null && i > coveredAt)) break;
      final step = await scroller.handle(session, scrollArgs);
      if (step.isError) {
        return StructuredResponse.error(
          summary: 'scroll step $i failed; aborting scroll_to_find',
          errorKind: GlintErrorKind.internal,
          detail: step.summary,
        );
      }
    }

    if (tapId != null && foundReply != null) {
      final tapped = await const TapTool().handle(session, CallToolRequest(name: 'tap', arguments: {'glintId': tapId}));
      return tapped.copyWith(summary: '${foundReply.summary}, ${tapped.summary}').mergeData({'found': foundReply.data});
    }

    // Return a diagnostic failure message that distinguishes the root cause.
    if (covered != null) {
      return StructuredResponse.error(
        summary: '$criterion was on screen but covered: a tap at its centre would land on ${_cover(covered)}',
        errorKind: GlintErrorKind.notHittable,
        detail: last > coveredAt!
            ? 'one more scroll did not uncover it, so scrolling further will not help'
            : 'covered on the last read allowed (maxScrolls $maxScrolls)',
        nextSteps: [
          'dismiss or move what is on top, then tap glintId:"${covered.glintId}"',
          'to only see it, call scroll_to_find without tap:true',
          'tap glintId:"${covered.glintId}" refuseNotHittable:false taps it anyway',
        ],
      ).mergeData({'glintId': covered.glintId, if (covered.hitBy != null) 'coveredBy': covered.hitBy});
    }
    if (seenInOverlay) {
      return StructuredResponse.error(
        summary: '$criterion is inside a modal overlay, not in the scrollable '
            'base screen — scrolling will not reach it',
        errorKind: GlintErrorKind.unresolvedTarget,
        nextSteps: const [
          'the target is visible in the dialog layer — use get_scene to read the '
              'overlay section and tap/type directly on the dialog element',
        ],
      );
    }
    if (seenInTree) {
      return StructuredResponse.error(
        summary: '$criterion appeared in the tree during scrolling but was never '
            'on-screen${tap ? ' and hittable' : ''} within $maxScrolls scroll(s) in $dirName — '
            'scroll limit hit',
        errorKind: GlintErrorKind.scrollLimitReached,
        nextSteps: [
          'increase `maxScrolls` (currently $maxScrolls)',
          'try the opposite direction in case content scrolled past the target',
          'use `get_scene` to check if a barrier or overlay is covering it',
        ],
      );
    }
    final hint = targetGlintId != null ? didYouMean(suggestIds(lastIds, targetGlintId)) : null;
    return StructuredResponse.error(
      summary: '$criterion was not found in any scene during $maxScrolls scroll(s) '
          'in $dirName — target is not in this list',
      errorKind: GlintErrorKind.targetNotFound,
      detail: lastTexts.isEmpty
          ? 'the screen shows no text at all'
          : 'text visible now: ${lastTexts.map((t) => '"$t"').join(", ")}',
      nextSteps: [
        if (hint != null) hint,
        'try a different `direction` (the target may be above/beside the viewport)',
        'if the text you want is not listed in detail, it lives on another '
            'screen or tab — navigate there first',
        'use `get_scene` to confirm the correct glintId or text content',
      ],
    );
  }

  /// What a tap at [c]'s centre reaches instead, as precisely as the hit test knows.
  static String _cover(ResolvedCoord c) =>
      c.hitBy ?? (c.hitTestReal ? 'another widget' : 'an absorber, overlay or modal (approximate check)');

  SceneNode? _findTextNode(SceneNode root, String needle) {
    final want = needle.toLowerCase();
    for (final n in root.walk()) {
      if (n.isOffstage) continue;
      final preview = n.textPreview;
      if (preview != null && preview.toLowerCase().contains(want)) return n;
    }
    return null;
  }

  /// Up to 12 distinct text snippets on screen, for the not-found hint.
  static List<String> _visibleTexts(SceneNode root, {int max = 12}) {
    final out = <String>[];
    for (final n in root.walk()) {
      if (n.isOffstage) continue;
      final t = n.textPreview?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t == null || t.isEmpty || out.contains(t)) continue;
      out.add(t.length > 40 ? '${t.substring(0, 39)}…' : t);
      if (out.length >= max) break;
    }
    return out;
  }
}
