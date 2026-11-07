import 'dart:io';

/// How many names [IdentityRedactor] replaced, by category; the counts say what happened without repeating any name.
class RedactionCounts {
  int apps = 0;
  int devices = 0;
  int hosts = 0;

  int get total => apps + devices + hosts;

  Map<String, int> toJson() => {'apps': apps, 'devices': devices, 'hosts': hosts};

  /// `3 app names, 1 device name, 2 hosts`; null when nothing was replaced.
  String? describe() {
    final parts = [
      if (apps > 0) '$apps app ${apps == 1 ? 'name' : 'names'}',
      if (devices > 0) '$devices device ${devices == 1 ? 'name' : 'names'}',
      if (hosts > 0) '$hosts ${hosts == 1 ? 'host' : 'hosts'}',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
}

enum _Category { app, device, host }

enum _Edge { none, word, strict }

class _Rule {
  _Rule(this.pattern, this.category, this.edge);

  final RegExp pattern;
  final _Category category;
  final _Edge edge;

  String get placeholder => switch (category) {
        _Category.app => '<app>',
        _Category.device => '<device>',
        _Category.host => '<host>',
      };

  String apply(String input, RedactionCounts counts) => input.replaceAllMapped(pattern, (m) {
        if (!_edgesHold(input, m.start, m.end, edge)) return m[0]!;
        counts.add(category);
        return placeholder;
      });
}

extension on RedactionCounts {
  void add(_Category c) {
    switch (c) {
      case _Category.app:
        apps++;
      case _Category.device:
        devices++;
      case _Category.host:
        hosts++;
    }
  }
}

/// Replaces the app, device and backend names a session knows with `<app>`, `<device>` and `<host>`, case-insensitively and across separators and camelCase; [counts] says how many.
class IdentityRedactor {
  IdentityRedactor({
    Iterable<String> appNames = const [],
    Iterable<String> deviceNames = const [],
    Iterable<String> hosts = const [],
  }) : this._(
          _hostRulesFor(hosts),
          _nameRules(deviceNames, _Category.device, generic: _genericDeviceWords),
          _nameRules(appNames, _Category.app),
        );

  IdentityRedactor._(({List<_Rule> exact, List<_Rule> tokens}) host, this._deviceRules, this._appRules)
      : _hostRules = host.exact,
        _hostTokenRules = host.tokens {
    known = _hostRules.length + _hostTokenRules.length + _deviceRules.length + _appRules.length;
  }

  final List<_Rule> _hostRules;
  final List<_Rule> _hostTokenRules;
  final List<_Rule> _deviceRules;
  final List<_Rule> _appRules;

  final RedactionCounts counts = RedactionCounts();

  /// How many patterns the given names produced; 0 means nothing from the session could be redacted.
  late final int known;

  String redact(String input) {
    if (input.isEmpty) return input;
    var s = input;
    for (final rule in _hostRules) {
      s = rule.apply(s, counts);
    }
    s = _sweepUrlHosts(s);
    for (final rule in _deviceRules) {
      s = rule.apply(s, counts);
    }
    for (final rule in _appRules) {
      s = rule.apply(s, counts);
    }
    for (final rule in _hostTokenRules) {
      s = rule.apply(s, counts);
    }
    return s;
  }

  String _sweepUrlHosts(String input) => input.replaceAllMapped(_urlHostRegex, (m) {
        final host = m[2]!;
        if (host.startsWith('[') || isPublicHost(host)) return m[0]!;
        counts.hosts++;
        return '${m[1]}<host>';
      });
}

/// Whether [host] is a well-known public service or a local address; anything else is treated as private.
bool isPublicHost(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (_localHostRegex.hasMatch(h)) return true;
  for (final entry in _publicHosts) {
    if (h == entry || h.endsWith('.$entry')) return true;
  }
  return false;
}

/// The folder name and the pubspec `name:` of the Flutter project at [dir], both of which name the app.
List<String> projectIdentityNames(String? dir) {
  if (dir == null || dir.isEmpty) return const [];
  final names = <String>[];
  final trimmed = dir.endsWith('/') || dir.endsWith(r'\') ? dir.substring(0, dir.length - 1) : dir;
  final base = trimmed.split(RegExp(r'[/\\]')).last;
  if (base.isNotEmpty) names.add(base);
  try {
    final pubspec = File('$trimmed${Platform.pathSeparator}pubspec.yaml');
    final name = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec.readAsStringSync())?.group(1);
    if (name != null) names.add(name);
  } on Object {
    return names;
  }
  return names;
}

({List<_Rule> exact, List<_Rule> tokens}) _hostRulesFor(Iterable<String> hosts) {
  final exact = <String, _Rule>{};
  final tokens = <String, _Rule>{};
  final seen = <String>{};
  for (final raw in hosts) {
    final host = raw.trim().toLowerCase();
    if (host.isEmpty || isPublicHost(host) || !seen.add(host)) continue;
    exact['0|${host.length.toString().padLeft(4, '0')}|$host'] = _Rule(
      RegExp(RegExp.escape(host), caseSensitive: false),
      _Category.host,
      _Edge.strict,
    );
    if (_ipRegex.hasMatch(host)) continue;
    final labels = host.split('.');
    for (final label in labels.take(labels.length > 1 ? labels.length - 1 : 1)) {
      for (final word in _identityWords(label)) {
        if (!_isDistinctive(word)) continue;
        tokens['1|${word.length.toString().padLeft(4, '0')}|$word'] = _tokenRule(word, _Category.host);
      }
    }
  }
  return (exact: _byPriority(exact), tokens: _byPriority(tokens));
}

List<_Rule> _nameRules(Iterable<String> names, _Category category, {Set<String> generic = const {}}) {
  final rules = <String, _Rule>{};
  for (final raw in names) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    final words = _identityWords(name);
    final specific = [
      for (final w in words)
        if (!generic.contains(w.toLowerCase()) && !_isNumber(w)) w,
    ];
    if (specific.isEmpty) continue;
    if (words.length >= 2) {
      final source = words.map(RegExp.escape).join(_wordJoiner);
      rules['0|${source.length.toString().padLeft(4, '0')}|$source'] = _Rule(
        RegExp(source, caseSensitive: false),
        category,
        _Edge.word,
      );
    }
    for (final word in specific) {
      if (!_isDistinctive(word)) continue;
      rules['1|${word.length.toString().padLeft(4, '0')}|${word.toLowerCase()}'] = _tokenRule(word, category);
    }
  }
  return _byPriority(rules);
}

_Rule _tokenRule(String word, _Category category) =>
    _Rule(RegExp(RegExp.escape(word), caseSensitive: false), category, word.length >= 7 ? _Edge.none : _Edge.word);

List<_Rule> _byPriority(Map<String, _Rule> rules) {
  final keys = rules.keys.toList()
    ..sort((a, b) {
      final kind = a[0].compareTo(b[0]);
      return kind != 0 ? kind : b.substring(2).compareTo(a.substring(2));
    });
  return [for (final k in keys) rules[k]!];
}

const _wordJoiner = r"(?:['’]s)?[\s._\-'’]*";

final RegExp _camelParts = RegExp(
  r'\p{Ll}\p{Lu}\p{Ll}+|\p{Ll}\p{Lu}{2,}(?!\p{Ll})|\p{Lu}+(?!\p{Ll})|\p{Lu}?\p{Ll}+|\p{Lo}+|\p{N}+',
  unicode: true,
);
final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _possessive = RegExp(r"['’]s\b");

List<String> _identityWords(String name) => [
      for (final chunk in name.replaceAll(_possessive, '').split(_separators))
        for (final m in _camelParts.allMatches(chunk)) m[0]!,
    ];

bool _isNumber(String word) => RegExp(r'^\p{N}+$', unicode: true).hasMatch(word);

bool _isDistinctive(String word) =>
    word.length >= 4 && RegExp(r'^\p{L}+$', unicode: true).hasMatch(word) && !_stopWords.contains(word.toLowerCase());

bool _isLetter(String ch) => RegExp(r'\p{L}', unicode: true).hasMatch(ch);
bool _isLower(String ch) => RegExp(r'\p{Ll}', unicode: true).hasMatch(ch);
bool _isUpper(String ch) => RegExp(r'\p{Lu}', unicode: true).hasMatch(ch);
bool _isAlnum(String ch) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch);

bool _edgesHold(String s, int start, int end, _Edge edge) {
  switch (edge) {
    case _Edge.none:
      return true;
    case _Edge.strict:
      return (start == 0 || !_isAlnum(s[start - 1])) && (end == s.length || !_isAlnum(s[end]));
    case _Edge.word:
      final leftOk = start == 0 || !_isLetter(s[start - 1]) || (_isLower(s[start - 1]) && _isUpper(s[start]));
      final rightOk = end == s.length || !_isLetter(s[end]) || (_isUpper(s[end]) && _isLower(s[end - 1]));
      return leftOk && rightOk;
  }
}

final RegExp _urlHostRegex = RegExp(r'''([A-Za-z][A-Za-z0-9+.\-]*://)([^/\s?#:'"<>()\]]+)''');
final RegExp _ipRegex = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _localHostRegex = RegExp(
  r'^(localhost|0\.0\.0\.0|10\.0\.2\.2|127\.\d+\.\d+\.\d+|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$',
);

const _publicHosts = {
  'googleapis.com',
  'google.com',
  'gstatic.com',
  'apple.com',
  'github.com',
  'githubusercontent.com',
  'pub.dev',
  'dart.dev',
  'flutter.dev',
  'example.com',
  'example.org',
  'example.net',
  'httpbin.org',
  'typicode.com',
  'npmjs.org',
};

final Set<String> _genericDeviceWords = {
  'iphone',
  'ipad',
  'ipod',
  'pro',
  'max',
  'plus',
  'mini',
  'ultra',
  'air',
  'simulator',
  'emulator',
  'pixel',
  'galaxy',
  'android',
  'sdk',
  'built',
  'for',
  'gphone',
  'phone',
  'tablet',
  'generation',
  'gen',
  'inch',
  'apple',
  'watch',
  'samsung',
  'google',
  'xiaomi',
  'redmi',
  'oneplus',
  'huawei',
  'motorola',
  'sony',
  'nokia',
  'realme',
  'oppo',
  'vivo',
  'honor',
  'fold',
  'flip',
  'lite',
  'edge',
  'note',
  'tab',
  'arm',
  'x',
  'se',
  'xl',
  'xr',
  'the',
  'mac',
  'desktop',
  'chrome',
  'web',
  'ios',
  'cellular',
  'wifi',
  'wi',
  'fi',
  'a',
  's',
  'ram',
  'gb',
  'tb',
};

final Set<String> _stopWords = (() {
  const words = '''
    about above across after again against album also always among another answer anyone anything app apple
    application applications apps around attach attached attaching authentication auto back backend background bank
    banking based because been before being below between bill billing body both bottom bottomsheet browse build
    builds built bundle button buttons call calls camera cancel card cards cart chat check checkout child children
    chrome class client close code color column come comes common company complete component config configuration
    connect connection console contact container content context continue control controller could counter create
    created current custom dark dart dashboard data database date debug default delete demo detail details developer
    device devices dialog didn direct disabled display does doesn done down download draft driver each edit email
    empty enabled end enter entry environment error errors even event events every example exception expected
    explore extra fail failed failure false feature feed field fields file files filter final find first fixture
    flow flutter focus following form format found frame from front full function gallery general generic get gets
    glint going good grid group guest handle happen happened happens have header hello help here hide hint hold home
    host hosts http https icon image images index info information initial input install instance interaction
    interface into issue item items just keep key keyboard kind label last layout lazy learn leave left less level
    library light like line link list lists live load loading local location lock locked login logo logout long look
    made main make many map maps match material maybe media menu message messages method might mobile mode model
    modal more most move much must name names native navigation need network never next none normal note notes
    nothing notification notifications null number object once only open option options order other over overlay
    package page pages panel parent part password path payment payments people percent permission phone photo
    picker picture pixel place plain platform play please plugin point popup post press pressed prev previous
    primary print private product production profile progress project projects prompt provider public push query
    question quick radio rather read ready real receipt record redacted release remove render report request required
    reset response result results return review right robot role root route router row runner running same save
    scene screen screenshot scroll scrollable search second section secure select selected send sent server
    service session set settings setup share shared sheet should show shows side sign simple simulator since
    single size skip slider small some something sometimes source space split stack staging stage start started
    state static status step still stop store stream string style submit success such support switch system
    table take target task team tell test testing text than that their theme them then there these they thing
    things this those through time title toast today toggle token tool tools top total touch track transaction
    transfer tree true type under unit unknown until update upload user users value values version very video view
    views wait want warning wasn watch welcome were what when where which while whole widget widgets will window
    with within without word work worker would write wrong your yours zero
  ''';
  return words.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();
})();
