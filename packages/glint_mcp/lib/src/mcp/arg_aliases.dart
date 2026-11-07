import '../../observability.dart' show looseNum;

/// One guessed argument name and what it becomes; [accepts] limits the rename to values that mean what the canonical key means.
class ArgAlias {
  const ArgAlias(this.to, {this.accepts, this.convert, this.note});

  /// The canonical key, or null to drop the guessed one.
  final String? to;
  final bool Function(Object? value, Map<String, Object?> args)? accepts;
  final Object? Function(Object? value)? convert;
  final String? note;
}

bool _isFraction(Object? v, Map<String, Object?> args) => v is num && v >= 0 && v <= 1;
bool _isString(Object? v, Map<String, Object?> args) => v is String;
bool _isBool(Object? v, Map<String, Object?> args) => v is bool;
bool _hasEnd(Object? v, Map<String, Object?> args) => args.containsKey('x2') && args.containsKey('y2');

const _dropped = ArgAlias(null, note: 'it has no effect here');
const _seconds =
    ArgAlias('timeoutMs', accepts: _isNumber, convert: _secondsToMs, note: 'seconds converted to milliseconds');

bool _isNumber(Object? v, Map<String, Object?> args) => looseNum(v) != null;

Object? _secondsToMs(Object? v) => (looseNum(v)! * 1000).round();

const _segmentAliases = <String, ArgAlias>{
  'fromX': ArgAlias('x1'),
  'fromY': ArgAlias('y1'),
  'toX': ArgAlias('x2'),
  'toY': ArgAlias('y2'),
  'startX': ArgAlias('x1'),
  'startY': ArgAlias('y1'),
  'endX': ArgAlias('x2'),
  'endY': ArgAlias('y2'),
  'from': ArgAlias('fromGlintId', accepts: _isString),
  'to': ArgAlias('toGlintId', accepts: _isString),
  'x': ArgAlias('x1', accepts: _hasEnd),
  'y': ArgAlias('y1', accepts: _hasEnd),
};

/// Wrong names agents guess per tool, with the canonical key each one means; the one place to add a rename.
const Map<String, Map<String, ArgAlias>> kToolArgAliases = {
  'swipe': _segmentAliases,
  'drag': _segmentAliases,
  'scroll': {'amount': ArgAlias('amountFraction', accepts: _isFraction)},
  'scroll_to_find': {
    'targetText': ArgAlias('targetTextContent'),
    'returnScene': _dropped,
  },
  'wait_for': {'timeoutSec': _seconds},
  'wait_for_settle': {'timeoutSec': _seconds},
  'hot_reload': {
    'full': ArgAlias('restart', accepts: _isBool),
    'fullRestart': ArgAlias('restart', accepts: _isBool),
  },
  'type': {'into': ArgAlias('focus', accepts: _isString)},
  'attach': {'inputRoute': ArgAlias('input', accepts: _isString)},
  'app_logs': {
    'grep': ArgAlias('contains', note: 'a case-insensitive substring match'),
    'filter': ArgAlias('contains', note: 'a case-insensitive substring match'),
    'query': ArgAlias('contains', note: 'a case-insensitive substring match'),
  },
  'batch': {'fetchScene': _dropped},
  'key': {'fetchScene': _dropped},
  'get_scene': {'fetchScene': _dropped},
};

/// Guesses that could mean more than one thing stay errors; the reply names the right key instead.
const Map<String, Map<String, String>> kArgHints = {
  'swipe': {
    'direction': 'swipe has no direction: pass x1,y1,x2,y2, or fromGlintId + toGlintId, or edge for a system gesture; '
        'to scroll a list use scroll direction:"down"',
    'distance': 'swipe has no distance: end it at x2,y2; to scroll a list use scroll amountFraction',
    'x': 'swipe takes a start x1,y1 and an end x2,y2',
    'y': 'swipe takes a start x1,y1 and an end x2,y2',
    'glintId': 'swipe takes fromGlintId and toGlintId',
  },
  'scroll': {
    'amount': 'scroll sizes by amountFraction, 0.0 to 1.0 of the viewport, not by pixels',
    'distance': 'scroll sizes by amountFraction, 0.0 to 1.0 of the viewport, not by distance',
    'x': 'scroll takes no point: it swipes the main scrollable; to move one list swipe x1,y1,x2,y2 inside it',
    'y': 'scroll takes no point: it swipes the main scrollable; to move one list swipe x1,y1,x2,y2 inside it',
    'glintId':
        'scroll takes no id: it swipes the main scrollable; scroll_to_find targetGlintId brings an item into view',
  },
  'wait_for': {
    'timeout': 'timeoutMs is in milliseconds, for example timeoutMs:10000',
  },
  'wait_for_settle': {
    'timeout': 'timeoutMs is in milliseconds, for example timeoutMs:10000',
  },
  'tap': {
    'input': 'tap has no input route: attach input:"auto|app|device" picks it once',
    'inputRoute': 'tap has no input route: attach input:"auto|app|device" picks it once',
    'via': 'tap has no input route: attach input:"auto|app|device" picks it once',
    'target': 'tap text:"<visible text>" or glintId:"<id>"',
    'count': 'to tap more than once pass sequence',
    'duration': 'a held press is long_press durationMs',
  },
  'long_press': {'duration': 'durationMs is in milliseconds'},
  'type': {
    'submit': 'type has no submit: follow it with key key:"enter"',
    'x': 'type into an input: focus:"<glintId>" taps it first',
    'y': 'type into an input: focus:"<glintId>" taps it first',
  },
  'get_scene': {'detail': 'get_scene takes format, glintId and depth'},
  'attach': {
    'detail': 'attach takes no detail: it reports what it found',
    'verbose': 'attach takes no verbose',
  },
  'record': {
    'op': 'record takes steps:[…] to record a flow, or durationMs for a timed capture',
  },
  'logs': {
    'grep':
        'logs lists glint\'s own calls: filter with tool:"<name>" or failuresOnly:true; app_logs contains:"…" searches the app',
  },
};

/// The renames applied to one call's arguments and the notes to show the agent.
class ArgAliasOutcome {
  final warnings = <String>[];
}

String _flat(String s) => s.toLowerCase().replaceAll(RegExp('[_-]'), '');

/// Renames guessed names in [args] to the canonical keys in [accepted], in place; the outcome says what changed.
ArgAliasOutcome applyArgAliases(
  String tool,
  Map<String, Object?> args,
  Set<String> accepted,
) {
  final outcome = ArgAliasOutcome();
  void rename(String wrong, ArgAlias alias) {
    final to = alias.to;
    if (!args.containsKey(wrong) || accepted.contains(wrong)) return;
    if (to != null && (!accepted.contains(to) || args.containsKey(to))) return;
    final value = args[wrong];
    if (alias.accepts != null && !alias.accepts!(value, args)) return;
    args.remove(wrong);
    if (to == null) {
      outcome.warnings.add(
        '$tool: `$wrong` is not an argument of $tool and was ignored (${alias.note})',
      );
      return;
    }
    args[to] = alias.convert == null ? value : alias.convert!(value);
    final why = alias.note == null ? '' : ' (${alias.note})';
    outcome.warnings.add(
      '$tool: `$wrong` is not an argument; used it as `$to`$why. Use `$to` next time',
    );
  }

  for (final entry in (kToolArgAliases[tool] ?? const <String, ArgAlias>{}).entries) {
    rename(entry.key, entry.value);
  }
  if (accepted.contains('op')) rename('action', const ArgAlias('op'));
  _joinCoordinates(tool, args, accepted, outcome);
  _matchSpelling(tool, args, accepted, outcome);
  return outcome;
}

void _joinCoordinates(
  String tool,
  Map<String, Object?> args,
  Set<String> accepted,
  ArgAliasOutcome outcome,
) {
  if (!accepted.contains('at') || args.containsKey('at')) return;
  for (final (lat, lng) in const [
    ('lat', 'lng'),
    ('latitude', 'longitude'),
    ('lat', 'lon'),
  ]) {
    final a = args[lat], b = args[lng];
    if (a is! num || b is! num || accepted.contains(lat)) continue;
    args
      ..remove(lat)
      ..remove(lng)
      ..['at'] = '$a,$b';
    outcome.warnings.add(
      '$tool: `$lat` and `$lng` are not arguments; used them as `at:"$a,$b"`. Use `at:"lat,lng"` next time',
    );
    return;
  }
}

void _matchSpelling(
  String tool,
  Map<String, Object?> args,
  Set<String> accepted,
  ArgAliasOutcome outcome,
) {
  for (final key in args.keys.where((k) => !accepted.contains(k)).toList()) {
    final same = accepted.where((a) => _flat(a) == _flat(key)).toList();
    if (same.length != 1 || args.containsKey(same.single)) continue;
    args[same.single] = args.remove(key);
    outcome.warnings.add(
      '$tool: `$key` is spelled `${same.single}`. Use `${same.single}` next time',
    );
  }
}

/// What to tell the agent about an unknown argument [key] of [tool] that no alias could fix; null when there is nothing specific.
String? argHint(String tool, String key) =>
    kArgHints[tool]?[key] ??
    (key == 'device'
        ? 'device is not an argument of $tool: use app:"<app label>" to pick another attached app, or attach device:"<id>" to change device'
        : null);
