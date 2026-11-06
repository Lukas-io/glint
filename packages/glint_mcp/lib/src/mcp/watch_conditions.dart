import 'dart:async';

import '../../interaction.dart' show GlintErrorKind;
import '../../observability.dart' show AlertKind, AppAlert;
import 'app_session.dart';
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

/// New alerts of the chosen [kinds]: an app error, uncaught error or overflow once per distinct error, each failed HTTP request, an app that ended, and (only when asked for) one that lost its VM connection or came back.
final class AlertsCondition extends WatchCondition {
  const AlertsCondition(this.kinds) : shorthand = false;

  /// `{errors:true}`: error, uncaught and overflow.
  const AlertsCondition.errors()
      : kinds = AlertKind.errorKinds,
        shorthand = true;

  final Set<AlertKind> kinds;
  final bool shorthand;

  bool get wantsHttp => kinds.contains(AlertKind.http);

  @override
  String get describe => shorthand ? 'new app error' : 'alerts ${kinds.map((k) => k.name).join(', ')}';

  @override
  Map<String, Object?> toJson() => shorthand
      ? {'errors': true}
      : {
          'alerts': [for (final k in kinds) k.name]
        };
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
  final Map<AppSession, StreamSubscription<AppAlert>> alertSubscriptions = {};
  final Set<AppSession> httpHeld = {};
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
      case LogCondition() || AlertsCondition() || LintCondition():
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

const _conditionExamples =
    'conditions:[{text:"Welcome back"}, {glintId:"home_tab", state:"disappears"}, {route:"/home"}, {overlay:"appears"}, {log:"payment .* failed"}, {errors:true}, {alerts:["overflow","http","terminated"]}, {lint:true}]';

/// Parsed `conditions`, or the invalidArgument reply naming the one that is wrong.
({List<WatchCondition>? conditions, StructuredResponse? error}) parseWatchConditions(Object? raw, {required int max}) {
  StructuredResponse bad(String summary, {String? detail, String? fix}) => StructuredResponse.error(
        summary: summary,
        errorKind: GlintErrorKind.invalidArgument,
        detail: detail ?? summary,
        nextSteps: [if (fix != null) fix, _conditionExamples],
      );

  if (raw is! List || raw.isEmpty) {
    return (
      conditions: null,
      error: bad('watch op:add needs a non-empty conditions list',
          detail: 'conditions was ${raw == null ? 'missing' : raw is List ? 'an empty list' : 'a ${raw.runtimeType}'}',
          fix: 'pass conditions as a list of 1-$max objects, e.g. conditions:[{text:"Welcome back"}]'),
    );
  }
  if (raw.length > max) {
    return (
      conditions: null,
      error: bad('at most $max conditions per watch, got ${raw.length}',
          detail: 'conditions has ${raw.length} entries, the limit is $max',
          fix: 'keep $max and add the rest as a second watch op:add'),
    );
  }
  const selectors = ['text', 'glintId', 'route', 'overlay', 'log', 'errors', 'alerts', 'lint'];
  const lintOptions = ['minTapTarget', 'maxHeadlineLines'];
  final out = <WatchCondition>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final where = 'conditions[$i]';
    if (item is! Map) {
      return (
        conditions: null,
        error: bad('$where must be an object',
            detail: '$where is a ${item.runtimeType}, each condition is an object with one selector',
            fix: 'write it as {text:"Welcome back"}'),
      );
    }
    final unknown = [
      for (final k in item.keys)
        if (!selectors.contains(k) && !lintOptions.contains(k) && k != 'state') '$k',
    ];
    if (unknown.isNotEmpty) {
      return (
        conditions: null,
        error: bad('$where: unknown field ${unknown.join(", ")}',
            detail: 'accepted: ${[...selectors, 'state', ...lintOptions].join(", ")}',
            fix: 'rename or remove ${unknown.join(", ")} in $where'),
      );
    }
    final given = [
      for (final k in selectors)
        if (item[k] != null) k,
    ];
    if (given.length != 1) {
      final optionsOnly = given.isEmpty && lintOptions.any(item.containsKey);
      return (
        conditions: null,
        error: bad('$where needs exactly one of ${selectors.join(", ")}',
            detail: 'it has ${given.isEmpty ? 'none' : given.join(" and ")}',
            fix: optionsOnly
                ? 'add lint to $where, e.g. {lint:["tapTarget"], minTapTarget:48}'
                : given.isEmpty
                    ? 'add one selector to $where, e.g. {text:"Welcome back"}'
                    : 'split $where into one object per selector: ${given.map((k) => '{$k:…}').join(', ')}'),
      );
    }
    final state = item['state'];
    final selector = given.single;
    if (selector != 'lint') {
      final stray = lintOptions.where(item.containsKey).toList();
      if (stray.isNotEmpty) {
        return (
          conditions: null,
          error: bad('$where: ${stray.join(' and ')} only ${stray.length == 1 ? 'goes' : 'go'} with lint',
              detail:
                  '$where has $selector and ${stray.join(' and ')}; ${lintOptions.join(' and ')} tune the lint rules',
              fix: 'move ${stray.join(' and ')} onto a lint condition, e.g. {lint:["tapTarget"], minTapTarget:48}, '
                  'and drop it from {$selector:…}'),
        );
      }
    }
    if (selector == 'lint') {
      final lint = _parseLint(item, where);
      if (lint.error != null) {
        return (conditions: null, error: bad(lint.error!, detail: lint.detail, fix: lint.fix));
      }
      out.add(lint.condition!);
      continue;
    }
    if (state != null && selector != 'text' && selector != 'glintId') {
      return (
        conditions: null,
        error: bad('$where: state only goes with text or glintId',
            detail: '$where has $selector and state "$state"; overlay uses appears or dismisses as its own value',
            fix: 'drop state from {$selector:…}, or use {text:"…", state:"disappears"}'),
      );
    }
    if (state != null && state != 'appears' && state != 'disappears') {
      return (
        conditions: null,
        error: bad('$where: state must be appears or disappears, got "$state"',
            detail: 'allowed states: appears (default), disappears', fix: 'use state:"appears" or state:"disappears"'),
      );
    }
    final value = item[selector];
    if (selector == 'errors') {
      if (value != true) {
        return (
          conditions: null,
          error: bad('$where: errors must be true',
              detail: 'errors was ${_show(value)}, it is a flag, not a filter', fix: 'use {errors:true}'),
        );
      }
      out.add(const AlertsCondition.errors());
      continue;
    }
    if (selector == 'alerts') {
      final alerts = _parseAlerts(value);
      if (alerts.error != null) {
        return (
          conditions: null,
          error: bad('$where: ${alerts.error}', fix: 'e.g. {alerts:["overflow","http","terminated"]}'),
        );
      }
      out.add(AlertsCondition(alerts.kinds!));
      continue;
    }
    if (selector == 'overlay') {
      if (value != 'appears' && value != 'dismisses') {
        return (
          conditions: null,
          error: bad('$where: overlay must be appears or dismisses, got "$value"',
              detail: 'allowed: appears, dismisses', fix: 'use {overlay:"appears"} or {overlay:"dismisses"}'),
        );
      }
      out.add(OverlayCondition(appears: value == 'appears'));
      continue;
    }
    if (value is! String) {
      return (
        conditions: null,
        error: bad('$where: $selector must be a string',
            detail: '$selector was ${_show(value)} (${value.runtimeType})', fix: 'use {$selector:"…"}'),
      );
    }
    switch (selector) {
      case 'route':
        out.add(RouteCondition(value.trim()));
      case 'log':
        if (value.isEmpty) {
          return (
            conditions: null,
            error: bad('$where: log needs a regex',
                detail: 'log was an empty string, which would match every line', fix: 'use {log:"payment .* failed"}'),
          );
        }
        try {
          out.add(LogCondition(RegExp(value)));
        } on FormatException catch (e) {
          return (
            conditions: null,
            error: bad('$where: log is not a valid regex',
                detail: e.message, fix: 'fix the pattern "$value" (Dart RegExp syntax) or escape special characters'),
          );
        }
      default:
        if (value.trim().isEmpty) {
          return (
            conditions: null,
            error: bad('$where: $selector is empty',
                detail: '$selector was blank, there is nothing to look for', fix: 'use {$selector:"Welcome back"}'),
          );
        }
        out.add(ShownCondition(
          text: selector == 'text' ? value : null,
          glintId: selector == 'glintId' ? value : null,
          appears: state != 'disappears',
        ));
    }
  }
  return (conditions: out, error: null);
}

typedef _LintParse = ({LintCondition? condition, String? error, String? detail, String? fix});

_LintParse _parseLint(Map item, String where) {
  _LintParse fail(String error, String detail, String fix) =>
      (condition: null, error: '$where: $error', detail: detail, fix: fix);

  final rulesHint = 'rules: ${lintRuleNames.join(', ')}';
  if (item['state'] != null) {
    return fail('state does not go with lint', 'lint conditions fire on problems, they have no appears or disappears',
        'drop state from $where, e.g. {lint:true}');
  }
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
      return fail('unknown lint rule ${unknown.join(', ')}', rulesHint,
          'use rules from the list, e.g. {lint:["overflow","tapTarget"]}');
    }
    rules = [
      for (final r in lintRuleNames)
        if (value.contains(r)) r,
    ];
  } else {
    return fail('lint must be true or a list of rules', 'lint was ${_show(value)}; $rulesHint',
        'use {lint:true} or {lint:["overflow","clippedText"]}');
  }
  final tap = item['minTapTarget'];
  if (tap != null && (tap is! num || tap < 1 || tap > 200)) {
    return fail(
        'minTapTarget must be 1-200 logical points',
        'minTapTarget was ${_show(tap)}; the default is ${LintCondition.defaultMinTapTarget.round()}',
        'use e.g. {lint:["tapTarget"], minTapTarget:48}');
  }
  final lines = item['maxHeadlineLines'];
  if (lines != null && (lines is! int || lines < 1 || lines > 10)) {
    return fail(
        'maxHeadlineLines must be a whole number from 1 to 10',
        'maxHeadlineLines was ${_show(lines)}; the default is ${LintCondition.defaultMaxHeadlineLines}',
        'use e.g. {lint:["lines"], maxHeadlineLines:3}');
  }
  return (
    condition: LintCondition(
      rules: rules,
      minTapTarget: (tap as num?)?.toDouble() ?? LintCondition.defaultMinTapTarget,
      maxHeadlineLines: (lines as int?) ?? LintCondition.defaultMaxHeadlineLines,
    ),
    error: null,
    detail: null,
    fix: null,
  );
}

String _show(Object? v) => v is String ? '"$v"' : '$v';

({Set<AlertKind>? kinds, String? error}) _parseAlerts(Object? value) {
  final accepted = AlertKind.values.map((k) => k.name).join(', ');
  if (value is! List || value.isEmpty) return (kinds: null, error: 'alerts must be a non-empty list of: $accepted');
  final kinds = <AlertKind>{};
  for (final item in value) {
    final kind = item is String ? AlertKind.named(item) : null;
    if (kind == null) return (kinds: null, error: 'unknown alert "$item", accepted: $accepted');
    kinds.add(kind);
  }
  return (kinds: kinds, error: null);
}
