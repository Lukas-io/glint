import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart' show CallProgress, SceneState, StateObserver;
import '../../../perception.dart';
import '../../../semantic.dart' show SemanticScene, kPagedLabels;
import '../envelope.dart';
import '../post_action.dart' show ScrollAnchor, SceneSnapshot, scrollDisplacement, sideEffectOf, snapshotOf;
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

/// The scrollable that moves [hit] along [dir]'s axis (not whatever sits under the default swipe point) and the PageViews around it that must stay on their page; a target with no anchor keeps the default swipe.
Future<ScrollTarget> scrollTargetFor(GlintSession session, Scene scene, SceneNode hit, ScrollDirection dir) async {
  const none = (anchor: null, watchedPagedIds: <String>{});
  final id = hit.glintId;
  if (id == null || scene.isInOverlay(id)) return none;
  try {
    final horizontal = dir == ScrollDirection.left || dir == ScrollDirection.right;
    final driven = await scrollableAround(session.runtime, scene, hit, horizontal: horizontal);
    final paged = [
      for (final a in _ancestorsOf(scene.root, hit))
        if (a.glintId != null && kPagedLabels.contains(a.baseLabel)) a.glintId!,
    ];
    final watched = {...paged.skip(driven != null && driven.paged ? 1 : 0)};
    if (driven == null) return (anchor: null, watchedPagedIds: watched);
    final coord = await session.resolver.resolve(scene, id);
    final anchor = coord.hasNonZeroBounds
        ? (glintId: id, x: coord.logicalCenter.x, y: coord.logicalCenter.y, clip: driven.rect)
        : null;
    return (anchor: anchor, watchedPagedIds: watched);
  } on Object {
    return none;
  }
}

/// [target]'s ancestors under [root], nearest first.
List<SceneNode> _ancestorsOf(SceneNode root, SceneNode target) {
  final path = <SceneNode>[];
  bool visit(SceneNode n) {
    if (identical(n, target)) return true;
    path.add(n);
    if (n.children.any(visit)) return true;
    path.removeLast();
    return false;
  }

  return visit(root) ? path.reversed.toList() : const [];
}

/// How a hold on a loading list ended.
enum _Hold { grew, indicatorGone, capped }

/// Loops `get_scene` + `scroll` until a target (glintId or text content)
/// is on screen (and hittable for tap:true), or the ceiling is reached. Stops early if already visible.
class ScrollToFindTool extends GlintTool {
  const ScrollToFindTool();

  @override
  bool changesDevice(Map<String, Object?> args) => true;

  @override
  Tool get definition => Tool(
        name: 'scroll_to_find',
        description:
            'Scroll until a target is on screen, then return its glintId (tap:true also taps it, so it must also be hittable). Match targetGlintId (exact id) or targetTextContent (substring of any text), not both. direction default down, maxScrolls 8 (cap 20, a larger value is clamped and the reply says so), amountFraction 0.6; progress every 10 s. It stops early when the list stops moving (end reached). When it stalls with a loading indicator showing it waits up to 4 s for rows to arrive before deciding it is at the end. Swipes the nearest scrollable around the target on that axis, and stops if the route or an outer PageView page changes. errorKind: targetNotFound (never appeared), scrollLimitReached (appeared, never on screen; detail says where it sat), notHittable (tap:true, on screen but covered), unresolvedTarget (inside a modal, not scrollable content), scrollSideEffect (route or outer page changed), flutterModeRequired (device mode).',
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
              description: 'Scroll ceiling, 0-20. Default 8.',
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

  static const _maxScrollsCap = 20;
  static const _maxDuration = Duration(seconds: 90);
  static const _stallsForEnd = 2;
  static const _restSamples = 3;
  static const _iterationAllowance = Duration(seconds: 20);
  static const _replyMargin = Duration(seconds: 20);
  static const _stalledShare = 0.25;
  static const _stalledMaxPx = 40.0;
  static const _settleAfterSwipeMs = 500;
  static const _loadWait = Duration(seconds: 4);
  static const _loadPoll = Duration(milliseconds: 400);
  static const _indicatorCheckEvery = 3;
  static const _shimmerLabels = {'Shimmer'};
  static final _loadingFooter = RegExp(
      r'^(loading|fetching|please wait)( more| next| items| results| page)?\s*(\.{2,3}|…)?$',
      caseSensitive: false);

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) =>
      _maxDuration + _iterationAllowance + _replyMargin;

  static ({int used, int? asked}) _scrollBudget(GlintSession session, Map<String, Object?> args) {
    final int? asked;
    try {
      asked = argInt(args, 'maxScrolls');
    } on ArgTypeError {
      return (used: session.config.scrollMaxScrolls.clamp(0, _maxScrollsCap), asked: null);
    }
    final wanted = asked ?? session.config.scrollMaxScrolls;
    final used = wanted.clamp(0, _maxScrollsCap);
    return (used: used, asked: asked != null && asked != used ? asked : null);
  }

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final budget = _scrollBudget(session, args);
    final StructuredResponse reply;
    try {
      reply = await _search(session, args, budget.used);
    } finally {
      CallProgress.note(null);
    }
    return reply.addWarnings([
      if (budget.asked != null)
        'maxScrolls ${budget.asked} is ${budget.asked! < 0 ? 'below the minimum of 0' : 'above the cap of $_maxScrollsCap'}; scrolled at most ${budget.used} time(s)',
    ]);
  }

  Future<StructuredResponse> _search(GlintSession session, Map<String, Object?> args, int maxScrolls) async {
    final targetGlintId = args['targetGlintId'] as String?;
    final targetText = (args['targetTextContent'] as String?) ?? (args['text'] as String?);
    final dirName = (args['direction'] as String?) ?? 'down';
    final amount = (argNum(args, 'amountFraction') ?? session.config.scrollAmountFraction).toDouble();
    final tap = argBool(args, 'tap') ?? false;

    if ((targetGlintId == null) == (targetText == null)) {
      return StructuredResponse.error(
        summary: 'exactly one of targetGlintId or targetTextContent is required',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const ['pass targetGlintId:"<id>" or targetTextContent:"<visible text>"'],
      );
    }

    final dir = enumByName(ScrollDirection.values, dirName);
    if (dir == null) {
      return StructuredResponse.error(
        summary: 'unknown scroll direction: $dirName',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: ['use one of: ${ScrollDirection.values.map((d) => d.name).join(', ')}'],
      );
    }
    final horizontal = dir == ScrollDirection.left || dir == ScrollDirection.right;

    final scrollArgs = CallToolRequest(name: 'scroll', arguments: {
      'direction': dir.name,
      'amountFraction': amount,
      'returnScene': false,
    });
    final scrollArgsWithReason =
        CallToolRequest(name: 'scroll', arguments: {...scrollArgs.arguments!, 'returnScene': true});
    final scroller = const ScrollTool();
    final criterion = targetGlintId != null ? 'glintId=$targetGlintId' : 'text~"$targetText"';
    final clock = Stopwatch()..start();

    var seenInTree = false;
    var seenInOverlay = false;
    var lastTexts = const <String>[];
    var lastIds = const <String>[];
    var stalls = 0;
    String? blockedDetail;
    ScrollTarget target = (anchor: null, watchedPagedIds: const <String>{});
    ScrollAnchor? swiped;
    ScrollAnchor? firstAnchor;
    final swipes = <String>[];
    var worstIteration = Duration.zero;
    SceneSnapshot? previous;
    ResolvedCoord? covered;
    ResolvedCoord? lastSeen;
    int? coveredAt;
    var last = 0;
    var endReached = false;
    var outOfTime = false;
    var loadGaveUp = false;
    var loadWaitedMs = 0;

    String? tapId;
    StructuredResponse? foundReply;
    for (var i = 0; i <= maxScrolls; i++) {
      last = i;
      final iterationClock = Stopwatch()..start();
      CallProgress.enter('scroll_to_find: reading the scene before scroll ${i + 1}', key: 'read');
      final scene = await session.reader.readSummary();
      try {
        lastTexts = _visibleTexts(scene.root);
        lastIds = scene.glintIds;
        SemanticScene? readSemantic;
        SceneSnapshot? readSnapshot;
        if (i > 0) {
          readSemantic = await session.semanticize(scene, detail: SceneDetail.structural);
          readSnapshot = snapshotOf(readSemantic);
          final sideEffect = sideEffectOf(previous, readSnapshot, target.watchedPagedIds);
          if (sideEffect != null) return _sideEffectReply(criterion, i, sideEffect, target);
        }
        CallProgress.note('scroll $i/$maxScrolls, last seen: ${lastTexts.take(6).map((t) => '"$t"').join(', ')}');
        final hit = targetGlintId != null ? scene.findByGlintId(targetGlintId) : _findTextNode(scene.root, targetText!);
        if (hit != null && hit.glintId != null) {
          seenInTree = true;
          if (targetGlintId != null && scene.isInOverlay(targetGlintId)) {
            seenInOverlay = true;
          }
          try {
            final coord = await session.resolver.resolve(scene, hit.glintId!);
            lastSeen = coord;
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
                  'elapsedMs': clock.elapsedMilliseconds,
                  if (loadWaitedMs > 0) 'loadWaitMs': loadWaitedMs,
                  'swipes': swipes,
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
            lastSeen = null;
          }
        }
        if (i < maxScrolls) {
          final semantic = readSemantic ?? await session.semanticize(scene, detail: SceneDetail.structural);
          final snapshot = readSnapshot ?? snapshotOf(semantic);
          var holdForLoad = false;
          String? holdAnchorId;
          Future<void> measureStall() async {
            if (i == 0 || i == maxScrolls) return;
            final before = swiped;
            final moved = before == null
                ? null
                : await scrollDisplacement(session, scene, before, horizontal, restSamples: _restSamples);
            final nearlyStill = moved != null && moved <= _stalledBelow(before!, amount, horizontal);
            holdForLoad = nearlyStill && !loadGaveUp && _loadingOnPage(semantic);
            holdAnchorId = before?.glintId;
            if (holdForLoad) return;
            stalls = nearlyStill ? stalls + 1 : 0;
            endReached = stalls >= _stallsForEnd;
          }

          previous = snapshot;
          await measureStall();
          target = hit != null && hit.glintId != null
              ? await scrollTargetFor(session, scene, hit, dir)
              : (anchor: await session.scrollAnchorIn(scene, semantic), watchedPagedIds: const <String>{});
          swiped = target.anchor;
          firstAnchor ??= swiped;
          final fixed = firstAnchor?.clip;
          final fresh = target.anchor;
          if (fresh != null && fixed != null && fresh.clip != fixed) {
            target = (
              anchor: (glintId: fresh.glintId, x: fresh.x, y: fresh.y, clip: fixed),
              watchedPagedIds: target.watchedPagedIds
            );
          } else if (fresh == null && firstAnchor != null) {
            target = (anchor: firstAnchor, watchedPagedIds: target.watchedPagedIds);
          }
          if (holdForLoad) {
            final waited = Stopwatch()..start();
            final held = await _holdForRows(session, scene, holdAnchorId, waited);
            loadWaitedMs += waited.elapsedMilliseconds;
            if (held == _Hold.grew) {
              stalls = 0;
            } else {
              stalls += 1;
              endReached = stalls >= _stallsForEnd;
              loadGaveUp = held == _Hold.capped;
            }
          }
        }
      } finally {
        await scene.dispose();
      }

      final spent = iterationClock.elapsed;
      if (spent > worstIteration) worstIteration = spent;
      outOfTime = clock.elapsed + worstIteration > _maxDuration;
      final done = tapId != null || i == maxScrolls || (coveredAt != null && i > coveredAt) || endReached || outOfTime;
      if (done) break;
      final verify = stalls > 0;
      if (!verify) blockedDetail = null;
      final step = await scroller.perform(session, verify ? scrollArgsWithReason : scrollArgs, target: target);
      swipes.add(step.summary.split(';').first);
      if (verify && step.data?['reason'] == 'blocked') blockedDetail = step.summary;
      if (step.isError) {
        return StructuredResponse.error(
          summary: 'scroll step $i failed; aborting scroll_to_find',
          errorKind: GlintErrorKind.internal,
          detail: step.summary,
          nextSteps: const [
            'get_scene to see the screen',
            'retry once; if it repeats, swipe x1,y1,x2,y2 inside the list'
          ],
        );
      }
      await _letScrollRest(session);
    }

    if (tapId != null && foundReply != null) {
      final tapped = await const TapTool().handle(session, CallToolRequest(name: 'tap', arguments: {'glintId': tapId}));
      return tapped.copyWith(summary: '${foundReply.summary}, ${tapped.summary}').mergeData({'found': foundReply.data});
    }

    if (endReached && blockedDetail != null && !seenInTree) {
      return StructuredResponse.error(
        summary: '$criterion was not found: the list can still move, but the swipe did not reach it',
        errorKind: GlintErrorKind.scrollLimitReached,
        detail: blockedDetail,
        nextSteps: const [
          'get_scene shows what sits over the list (a dialog, the keyboard or a bar); dismiss it, then retry',
          'or swipe x1,y1,x2,y2 inside the list',
        ],
      ).mergeData({'reason': 'blocked', 'attempts': last, 'elapsedMs': clock.elapsedMilliseconds});
    }
    final stopped = _whyStopped(endReached: endReached, outOfTime: outOfTime, scrolls: last, maxScrolls: maxScrolls);
    final loadNote = loadGaveUp
        ? '; a loading indicator was still showing and no rows arrived in ${_loadWait.inSeconds} s, so if the list loads more later, try again'
        : '';
    final progress = {
      'attempts': last,
      'elapsedMs': clock.elapsedMilliseconds,
      'swipes': swipes,
      if (endReached) 'endReached': true,
      if (loadWaitedMs > 0) 'loadWaitMs': loadWaitedMs,
    };

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
      ).mergeData({'glintId': covered.glintId, if (covered.hitBy != null) 'coveredBy': covered.hitBy, ...progress});
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
        summary: '$criterion appeared in the tree but was never on screen${tap ? ' and hittable' : ''}: $stopped',
        errorKind: GlintErrorKind.scrollLimitReached,
        detail:
            '${lastSeen == null ? 'it was in the tree but could not be measured' : _whereItSat(lastSeen, dir)}$loadNote',
        nextSteps: [
          if (!endReached && !outOfTime && last >= maxScrolls && maxScrolls < _maxScrollsCap)
            'raise maxScrolls (currently $maxScrolls, cap $_maxScrollsCap)',
          'try the opposite direction in case content scrolled past the target',
          'get_scene shows whether a barrier, overlay or another scrollable holds it',
        ],
      ).mergeData({if (lastSeen != null) 'glintId': lastSeen.glintId, ...progress});
    }
    final hint = targetGlintId != null ? didYouMean(suggestIds(lastIds, targetGlintId)) : null;
    return StructuredResponse.error(
      summary: '$criterion was not found in any scene: $stopped',
      errorKind: GlintErrorKind.targetNotFound,
      detail: (lastTexts.isEmpty
              ? 'the screen shows no text at all'
              : 'text visible now: ${lastTexts.map((t) => '"$t"').join(", ")}') +
          loadNote,
      nextSteps: [
        if (hint != null) hint,
        'try a different `direction` (the target may be above/beside the viewport)',
        'if the text you want is not listed in detail, it lives on another '
            'screen or tab — navigate there first',
        'use `get_scene` to confirm the correct glintId or text content',
      ],
    ).mergeData(progress);
  }

  static String _whyStopped({
    required bool endReached,
    required bool outOfTime,
    required int scrolls,
    required int maxScrolls,
  }) {
    if (endReached) return 'the list stopped moving after $scrolls scroll(s), so it has reached its end';
    if (outOfTime) return 'stopped after $scrolls scroll(s) because the search used its ${_maxDuration.inSeconds} s';
    return 'it did not appear within $maxScrolls scroll(s)';
  }

  /// Where a target that is in the tree but not usable sat at the last read, in words.
  static String _whereItSat(ResolvedCoord c, ScrollDirection dir) {
    final view = c.logicalViewSize;
    final x = c.logicalCenter.x.round(), y = c.logicalCenter.y.round();
    final where = [
      if (c.logicalCenter.y >= view.h) '${(c.logicalCenter.y - view.h).round()} px below the screen',
      if (c.logicalCenter.y < 0) '${(-c.logicalCenter.y).round()} px above the screen',
      if (c.logicalCenter.x >= view.w) '${(c.logicalCenter.x - view.w).round()} px right of the screen',
      if (c.logicalCenter.x < 0) '${(-c.logicalCenter.x).round()} px left of the screen',
    ];
    if (where.isNotEmpty) return 'at the last read its centre was at ($x, $y), ${where.join(' and ')}';
    if (!c.painted) {
      return 'at ($x, $y) on screen but not painted (hidden, clipped or faded); a tap there would reach ${_cover(c)}';
    }
    return 'at ($x, $y) inside its scrollable but clipped out of view; a tap there would reach ${_cover(c)}';
  }

  /// Travel under which a swipe counts as not having moved the list: a rubber-band overshoot at the end moves it a little, a real step far more.
  static double _stalledBelow(ScrollAnchor anchor, double amount, bool horizontal) {
    final clip = anchor.clip;
    final span = clip == null ? 600.0 : (horizontal ? clip.w : clip.h);
    return (span * amount * _stalledShare).clamp(2.0, _stalledMaxPx);
  }

  /// Holds a stalled list while a loading indicator shows: ends as soon as its scroll extent grows, when the indicator is gone, or after [_loadWait].
  Future<_Hold> _holdForRows(GlintSession session, Scene scene, String? anchorId, Stopwatch waited) async {
    final start = (await readScrollPosition(session, scene, anchorId)).position?.$3;
    for (var poll = 1; waited.elapsed < _loadWait; poll++) {
      CallProgress.enter(
          'scroll_to_find: waiting for the list to load more (${waited.elapsed.inSeconds} s of ${_loadWait.inSeconds} s)',
          key: 'settle');
      final left = _loadWait - waited.elapsed;
      await Future<void>.delayed(left < _loadPoll ? left : _loadPoll);
      final extent = (await readScrollPosition(session, scene, anchorId)).position?.$3;
      if (start != null && extent != null && extent > start + 1) return _Hold.grew;
      if (poll % _indicatorCheckEvery == 0 && !await _indicatorShowing(session)) return _Hold.indicatorGone;
    }
    return _Hold.capped;
  }

  Future<bool> _indicatorShowing(GlintSession session) async {
    final scene = await session.reader.readSummary();
    try {
      return _loadingOnPage(await session.semanticize(scene, detail: SceneDetail.structural));
    } finally {
      await scene.dispose();
    }
  }

  /// Whether the active page or an overlay shows a progress indicator, a shimmer or a short "Loading more" row.
  static bool _loadingOnPage(SemanticScene semantic) {
    if (const StateObserver().observe(semantic) == SceneState.loading) return true;
    final id = semantic.root.glintId;
    final page = id == null ? null : semantic.sourceFor(id);
    for (final root in [if (page != null) page, ...semantic.sourceScene.overlayRoots]) {
      for (final n in root.walk()) {
        if (n.isOffstage) continue;
        if (_shimmerLabels.contains(n.baseLabel)) return true;
        final text = n.textPreview?.trim();
        if (text != null && _loadingFooter.hasMatch(text)) return true;
      }
    }
    return false;
  }

  Future<void> _letScrollRest(GlintSession session) async {
    try {
      await session.settleDetector.awaitSettle(
        ceilingMs: _settleAfterSwipeMs,
        quietFramesNeeded: 2,
        checkLoadingAffordances: false,
      );
    } on Object {
      return;
    }
  }

  static StructuredResponse _sideEffectReply(String criterion, int scrolls, String sideEffect, ScrollTarget target) =>
      StructuredResponse.error(
        summary: 'stopped looking for $criterion after $scrolls scroll(s): $sideEffect. '
            'glint stopped to avoid more side effects',
        errorKind: GlintErrorKind.scrollSideEffect,
        detail: target.anchor == null
            ? 'glint found no scrollable around the target that moves along this direction, so the swipe used the default point and reached an outer one'
            : 'the swipe was aimed at the nearest scrollable around the target, yet something outside it moved too',
        nextSteps: const [
          'get_scene to see where the app is now',
          'go back first: pop the route, or swipe the PageView back to the page it was on',
          'then swipe or drag with x1,y1,x2,y2 inside the container that holds the target (resolve glintId:"<container>" gives its bounds)',
        ],
      ).mergeData({'attempts': scrolls, 'sideEffect': sideEffect});

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
