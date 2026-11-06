import 'dart:async';

import '../../interaction.dart' show GlintErrorKind;
import 'envelope.dart';
import 'watch_observation.dart';

/// One thing a watch waits for.
sealed class WatchCondition {
  const WatchCondition();

  String get describe;

  Map<String, Object?> toJson();
}

/// A text or glintId on screen (`appears`) or gone from it (`disappears`).
final class ShownCondition extends WatchCondition {
  const ShownCondition({this.text, this.glintId, required this.appears});

  final String? text;
  final String? glintId;
  final bool appears;

  @override
  String get describe => '${text != null ? 'text "$text"' : 'glintId $glintId'} ${appears ? 'appears' : 'disappears'}';

  @override
  Map<String, Object?> toJson() => {
        if (text != null) 'text': text,
        if (glintId != null) 'glintId': glintId,
        'state': appears ? 'appears' : 'disappears',
      };
}

/// The route changing, to [to] when named, to anything when empty.
final class RouteCondition extends WatchCondition {
  const RouteCondition(this.to);

  final String to;

  @override
  String get describe => to.isEmpty ? 'route changes' : 'route becomes "$to"';

  @override
  Map<String, Object?> toJson() => {'route': to};
}

/// A dialog, sheet or system surface coming up or going away.
final class OverlayCondition extends WatchCondition {
  const OverlayCondition({required this.appears});

  final bool appears;

  @override
  String get describe => 'overlay ${appears ? 'appears' : 'dismisses'}';

  @override
  Map<String, Object?> toJson() => {'overlay': appears ? 'appears' : 'dismisses'};
}

/// A new app log line matching [pattern].
final class LogCondition extends WatchCondition {
  const LogCondition(this.pattern);

  final RegExp pattern;

  @override
  String get describe => 'log /${pattern.pattern}/';

  @override
  Map<String, Object?> toJson() => {'log': pattern.pattern};
}

/// An error the app has not reported before: one hit per distinct summary and location, never for repeats.
final class ErrorsCondition extends WatchCondition {
  const ErrorsCondition();

  @override
  String get describe => 'new app error';

  @override
  Map<String, Object?> toJson() => {'errors': true};
}

/// Every rule `{lint:[…]}` accepts.
const lintRuleNames = ['overflow', 'keyboard', 'insets', 'tapTarget', 'clippedText', 'lines'];

/// UX lint over the live render tree: [rules] to run, with the tap target and headline thresholds.
final class LintCondition extends WatchCondition {
  const LintCondition({required this.rules, required this.minTapTarget, required this.maxHeadlineLines});

  static const defaultMinTapTarget = 44.0;
  static const defaultMaxHeadlineLines = 2;

  final List<String> rules;
  final double minTapTarget;
  final int maxHeadlineLines;

  @override
  String get describe => 'ux lint (${rules.join(', ')})';

  @override
  Map<String, Object?> toJson() => {
        'lint': rules,
        if (rules.contains('tapTarget')) 'minTapTarget': minTapTarget,
        if (rules.contains('lines')) 'maxHeadlineLines': maxHeadlineLines,
      };
}

/// A hit on an [ArmedCondition]: what matched, plus extra event fields.
typedef ConditionHit = ({String matched, Map<String, Object?> extra});

/// A [WatchCondition] with the state it needs between ticks.
class ArmedCondition {
  ArmedCondition(this.spec);

  final WatchCondition spec;
  bool? _satisfied;
  StreamSubscription<Object?>? logSubscription;
  StreamSubscription<Object?>? errorSubscription;
  DateTime? lastLogHit;
  int suppressedLogHits = 0;

  /// The hit when [now] makes this condition newly true against [before]; text and glintId conditions also fire on the first read, as `wait_for` does.
  ConditionHit? check(WatchObservation? before, WatchObservation now) {
    switch (spec) {
      case ShownCondition(:final text, :final glintId, :final appears):
        final shown = text != null ? now.textShown[text] : now.idShown[glintId];
        if (shown == null) return null;
        final satisfied = shown == appears;
        final fresh = satisfied && _satisfied != true;
        _satisfied = satisfied;
        return fresh ? (matched: text ?? glintId!, extra: const {}) : null;
      case RouteCondition(:final to):
        if (before == null || before.route == now.route) return null;
        if (to.isNotEmpty && _routeKey(now.route) != _routeKey(to)) return null;
        return (matched: now.route, extra: {'from': before.route});
      case OverlayCondition(:final appears):
        if (before == null || before.overlay == now.overlay || now.overlay != appears) return null;
        return (matched: appears ? now.overlayKind ?? 'overlay' : 'overlay dismissed', extra: const {});
      case LogCondition() || ErrorsCondition() || LintCondition():
        return null;
    }
  }

  /// Whether this condition is decided by reading the screen.
  bool get readsScene =>
      spec is ShownCondition || spec is RouteCondition || spec is OverlayCondition || spec is LintCondition;

  static String _routeKey(String route) {
    final r = route.trim().toLowerCase();
    return r.startsWith('/') ? r : '/$r';
  }
}

/// Parsed `conditions`, or the invalidArgument reply naming the one that is wrong.
({List<WatchCondition>? conditions, StructuredResponse? error}) parseWatchConditions(Object? raw, {required int max}) {
  StructuredResponse bad(String summary, {String? detail}) => StructuredResponse.error(
        summary: summary,
        errorKind: GlintErrorKind.invalidArgument,
        detail: detail,
        nextSteps: const [
          'conditions:[{text:"Welcome back"}, {glintId:"home_tab", state:"disappears"}, {route:"/home"}, {overlay:"appears"}, {log:"payment .* failed"}, {errors:true}, {lint:true}]',
        ],
      );

  if (raw is! List || raw.isEmpty) {
    return (conditions: null, error: bad('watch op:add needs a non-empty conditions list'));
  }
  if (raw.length > max) return (conditions: null, error: bad('at most $max conditions per watch, got ${raw.length}'));
  const selectors = ['text', 'glintId', 'route', 'overlay', 'log', 'errors', 'lint'];
  const lintOptions = ['minTapTarget', 'maxHeadlineLines'];
  final out = <WatchCondition>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final where = 'conditions[$i]';
    if (item is! Map) return (conditions: null, error: bad('$where must be an object'));
    final unknown = [
      for (final k in item.keys)
        if (!selectors.contains(k) && !lintOptions.contains(k) && k != 'state') '$k',
    ];
    if (unknown.isNotEmpty) {
      return (
        conditions: null,
        error: bad('$where: unknown field ${unknown.join(", ")}',
            detail: 'accepted: ${[...selectors, 'state', ...lintOptions].join(", ")}'),
      );
    }
    final given = [
      for (final k in selectors)
        if (item[k] != null) k,
    ];
    if (given.length != 1) {
      return (
        conditions: null,
        error: bad('$where needs exactly one of ${selectors.join(", ")}',
            detail: 'it has ${given.isEmpty ? 'none' : given.join(" and ")}'),
      );
    }
    final state = item['state'];
    final selector = given.single;
    if (selector != 'lint' && lintOptions.any(item.containsKey)) {
      return (conditions: null, error: bad('$where: ${lintOptions.join(' and ')} only go with lint'));
    }
    if (selector == 'lint') {
      final lint = _parseLint(item, where);
      if (lint.error != null) return (conditions: null, error: bad(lint.error!, detail: lint.detail));
      out.add(lint.condition!);
      continue;
    }
    if (state != null && selector != 'text' && selector != 'glintId') {
      return (conditions: null, error: bad('$where: state only goes with text or glintId'));
    }
    if (state != null && state != 'appears' && state != 'disappears') {
      return (conditions: null, error: bad('$where: state must be appears or disappears, got "$state"'));
    }
    final value = item[selector];
    if (selector == 'errors') {
      if (value != true) return (conditions: null, error: bad('$where: errors must be true'));
      out.add(const ErrorsCondition());
      continue;
    }
    if (selector == 'overlay') {
      if (value != 'appears' && value != 'dismisses') {
        return (conditions: null, error: bad('$where: overlay must be appears or dismisses, got "$value"'));
      }
      out.add(OverlayCondition(appears: value == 'appears'));
      continue;
    }
    if (value is! String) return (conditions: null, error: bad('$where: $selector must be a string'));
    switch (selector) {
      case 'route':
        out.add(RouteCondition(value.trim()));
      case 'log':
        if (value.isEmpty) return (conditions: null, error: bad('$where: log needs a regex'));
        try {
          out.add(LogCondition(RegExp(value)));
        } on FormatException catch (e) {
          return (conditions: null, error: bad('$where: log is not a valid regex', detail: e.message));
        }
      default:
        if (value.trim().isEmpty) return (conditions: null, error: bad('$where: $selector is empty'));
        out.add(ShownCondition(
          text: selector == 'text' ? value : null,
          glintId: selector == 'glintId' ? value : null,
          appears: state != 'disappears',
        ));
    }
  }
  return (conditions: out, error: null);
}

({LintCondition? condition, String? error, String? detail}) _parseLint(Map item, String where) {
  ({LintCondition? condition, String? error, String? detail}) fail(String error, [String? detail]) =>
      (condition: null, error: '$where: $error', detail: detail);

  if (item['state'] != null) return fail('state does not go with lint');
  final value = item['lint'];
  final List<String> rules;
  if (value == true) {
    rules = lintRuleNames;
  } else if (value is List && value.isNotEmpty) {
    final unknown = [
      for (final r in value)
        if (r is! String || !lintRuleNames.contains(r)) '$r',
    ];
    if (unknown.isNotEmpty) {
      return fail('unknown lint rule ${unknown.join(', ')}', 'rules: ${lintRuleNames.join(', ')}');
    }
    rules = [
      for (final r in lintRuleNames)
        if (value.contains(r)) r,
    ];
  } else {
    return fail('lint must be true or a list of rules', 'rules: ${lintRuleNames.join(', ')}');
  }
  final tap = item['minTapTarget'];
  if (tap != null && (tap is! num || tap < 1 || tap > 200)) return fail('minTapTarget must be 1-200 logical points');
  final lines = item['maxHeadlineLines'];
  if (lines != null && (lines is! int || lines < 1 || lines > 10)) return fail('maxHeadlineLines must be 1-10');
  return (
    condition: LintCondition(
      rules: rules,
      minTapTarget: (tap as num?)?.toDouble() ?? LintCondition.defaultMinTapTarget,
      maxHeadlineLines: (lines as int?) ?? LintCondition.defaultMaxHeadlineLines,
    ),
    error: null,
    detail: null,
  );
}
