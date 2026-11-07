import 'dart:io';

import 'redaction.dart';

/// How many names [IdentityRedactor] replaced, by category; the counts say what happened without repeating any name.
class RedactionCounts {
  int apps = 0;
  int devices = 0;
  int hosts = 0;

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

  void _add(_Category c) {
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
        counts._add(category);
        return placeholder;
      });
}

/// Replaces the app, device and host names a session knows with `<app>`, `<device>` and `<host>`; build one per report and reuse it for every field, [counts] and [warnings] accumulate.
class IdentityRedactor {
  IdentityRedactor({
    Iterable<String> appNames = const [],
    Iterable<String> deviceNames = const [],
    Iterable<String> hosts = const [],
  }) {
    _hostRules = _hostRulesFor(hosts);
    _deviceRules = _nameRulesFor(deviceNames, _Category.device, warnings);
    _appRules = _nameRulesFor(appNames, _Category.app, warnings);
  }

  late final List<_Rule> _hostRules;
  late final List<_Rule> _deviceRules;
  late final List<_Rule> _appRules;

  final RedactionCounts counts = RedactionCounts();

  /// Names too generic or too short to redact loosely, which the agent should check by hand.
  final Set<String> warnings = {};

  /// Paths, then secrets, then the known names, so a name inside a token cannot split it.
  String forSharing(String input) => redact(redactSecrets(redactPath(input)));

  String redact(String input) {
    if (input.isEmpty) return input;
    var s = input;
    for (final rule in _hostRules) {
      s = rule.apply(s, counts);
    }
    s = _sweepUrls(s);
    for (final rule in _deviceRules) {
      s = rule.apply(s, counts);
    }
    for (final rule in _appRules) {
      s = rule.apply(s, counts);
    }
    return _sweepBareHosts(s);
  }

  String _sweepUrls(String input) => input.replaceAllMapped(_urlRegex, (m) {
        final authority = m[2]!;
        final at = authority.lastIndexOf('@');
        final hostPort = at < 0 ? authority : authority.substring(at + 1);
        final colon = hostPort.startsWith('[') ? -1 : hostPort.indexOf(':');
        final host = colon < 0 ? hostPort : hostPort.substring(0, colon);
        final port = colon < 0 ? '' : hostPort.substring(colon);
        final hide = host.isNotEmpty && !host.startsWith('[') && !isPublicHost(host);
        if (!hide && at < 0) return m[0]!;
        if (hide) counts.hosts++;
        return '${m[1]}${at < 0 ? '' : '<redacted>@'}${hide ? '<host>' : host}$port';
      });

  String _sweepBareHosts(String input) => input.replaceAllMapped(_bareHostRegex, (m) {
        final host = m[1]!.toLowerCase();
        if (!_looksLikeHostname(host) || isPublicHost(host)) return m[0]!;
        counts.hosts++;
        return '<host>';
      });
}

/// Whether [host] is a well-known public service or a local address; anything else is treated as private.
bool isPublicHost(String host) {
  final h = host.toLowerCase().replaceAll(_trailingDot, '');
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
  final base = trimmed.split(_pathSeparators).last;
  if (base.isNotEmpty) names.add(base);
  try {
    final pubspec = File('$trimmed${Platform.pathSeparator}pubspec.yaml');
    final name = _pubspecName.firstMatch(pubspec.readAsStringSync())?.group(1);
    if (name != null) names.add(name);
  } on Object {
    return names;
  }
  return names;
}

bool _looksLikeHostname(String host) {
  final labels = host.split('.');
  final tld = labels.last;
  final rest = labels.sublist(0, labels.length - 1);
  if (rest.every(_versionLabel.hasMatch)) return false;
  if (_fileExtensions.contains(tld)) return false;
  if (_wantedTlds.contains(tld)) return !_needsDepth.contains(tld) || labels.length >= 3;
  return _countryTlds.contains(tld) || (_collidingTlds.contains(tld) && labels.length >= 3);
}

List<_Rule> _hostRulesFor(Iterable<String> hosts) {
  final rules = <String, _Rule>{};
  for (final raw in hosts) {
    final host = raw.trim().toLowerCase().replaceAll(_trailingDot, '');
    if (!host.contains('.') || isPublicHost(host)) continue;
    final names = {host, if (!_ipRegex.hasMatch(host)) _registrableDomain(host.split('.'))};
    for (final name in names) {
      if (isPublicHost(name)) continue;
      rules['${name.length.toString().padLeft(4, '0')}|$name'] = _Rule(
        RegExp(RegExp.escape(name), caseSensitive: false),
        _Category.host,
        _Edge.strict,
      );
    }
  }
  return _byLength(rules);
}

String _registrableDomain(List<String> labels) {
  if (labels.length <= 2) return labels.join('.');
  final deep = labels.last.length == 2 && _secondLevels.contains(labels[labels.length - 2]);
  return labels.sublist(labels.length - (deep ? 3 : 2)).join('.');
}

List<_Rule> _nameRulesFor(Iterable<String> names, _Category category, Set<String> warnings) {
  final rules = <String, _Rule>{};
  final label = category == _Category.app ? 'app' : 'device';
  final generic = category == _Category.device ? _genericDeviceWords : const <String>{};
  bool common(String w) => _isNumber(w) || _stopWords.contains(w.toLowerCase()) || generic.contains(w.toLowerCase());
  for (final raw in names) {
    final name = raw.trim();
    if (name.isEmpty || _glintNames.contains(name.toLowerCase())) continue;
    final words = _identityWords(name);
    final tokens = [
      for (final w in words)
        if (_isDistinctive(w) && !generic.contains(w.toLowerCase())) w,
    ];
    final phrase = words.length >= 2 && words.any((w) => !common(w));
    if (phrase) {
      final source = words.map(RegExp.escape).join(_wordJoiner);
      rules['0|${source.length.toString().padLeft(4, '0')}|$source'] = _Rule(
        RegExp(source, caseSensitive: false),
        category,
        _Edge.word,
      );
    }
    for (final word in tokens) {
      rules['1|${word.length.toString().padLeft(4, '0')}|${word.toLowerCase()}'] = _tokenRule(word, category);
    }
    if (phrase || tokens.isNotEmpty) continue;
    final everyWordCommon = words.every(common);
    if (category == _Category.device && words.every((w) => _isNumber(w) || generic.contains(w.toLowerCase()))) {
      continue;
    }
    rules['2|${name.length.toString().padLeft(4, '0')}|$name'] = _Rule(
      RegExp(RegExp.escape(name)),
      category,
      _Edge.strict,
    );
    warnings.add(
      everyWordCommon
          ? 'the $label name $name is a common word; check the draft'
          : 'the $label name $name is too short to match loosely; check the draft',
    );
  }
  return _byPriority(rules);
}

_Rule _tokenRule(String word, _Category category) =>
    _Rule(RegExp(RegExp.escape(word), caseSensitive: false), category, word.length >= 7 ? _Edge.none : _Edge.word);

List<_Rule> _byLength(Map<String, _Rule> rules) {
  final keys = rules.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final k in keys) rules[k]!];
}

List<_Rule> _byPriority(Map<String, _Rule> rules) {
  final keys = rules.keys.toList()
    ..sort((a, b) {
      final kind = a[0].compareTo(b[0]);
      return kind != 0 ? kind : b.substring(2).compareTo(a.substring(2));
    });
  return [for (final k in keys) rules[k]!];
}

List<String> _identityWords(String name) => [
      for (final chunk in name.replaceAll(_possessive, '').split(_separators))
        for (final m in _camelParts.allMatches(chunk)) m[0]!,
    ];

bool _isNumber(String word) => _digitsOnly.hasMatch(word);

bool _isDistinctive(String word) =>
    word.length >= 4 && _lettersOnly.hasMatch(word) && !_stopWords.contains(word.toLowerCase());

bool _isLetter(String ch) => _letter.hasMatch(ch);
bool _isLower(String ch) => _lower.hasMatch(ch);
bool _isUpper(String ch) => _upper.hasMatch(ch);
bool _isAlnum(String ch) => _alnum.hasMatch(ch);

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

const _wordJoiner = r"(?:['’]s)?[\s._\-'’]*";

final RegExp _camelParts = RegExp(
  r'\p{Ll}\p{Lu}\p{Ll}+|\p{Ll}\p{Lu}{2,}(?!\p{Ll})|\p{Lu}+(?!\p{Ll})|\p{Lu}?\p{Ll}+|\p{Lo}+|\p{N}+',
  unicode: true,
);
final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _possessive = RegExp(r"['’]s\b");
final RegExp _digitsOnly = RegExp(r'^\p{N}+$', unicode: true);
final RegExp _lettersOnly = RegExp(r'^\p{L}+$', unicode: true);
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _lower = RegExp(r'\p{Ll}', unicode: true);
final RegExp _upper = RegExp(r'\p{Lu}', unicode: true);
final RegExp _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _trailingDot = RegExp(r'\.$');
final RegExp _pathSeparators = RegExp(r'[/\\]');
final RegExp _pubspecName = RegExp(r'^name:\s*(\S+)', multiLine: true);
final RegExp _versionLabel = RegExp(r'^v?\d+$');
final RegExp _urlRegex = RegExp(r'''\b((?:https?|wss?)://)([^/\s?#'"<>()\]]*)''', caseSensitive: false);
final RegExp _bareHostRegex = RegExp(
  r'(?<![A-Za-z0-9_\-./\\])((?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,24})(?![A-Za-z0-9\-]|\.[A-Za-z0-9])',
);
final RegExp _ipRegex = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _localHostRegex = RegExp(
  r'^(localhost|0\.0\.0\.0|10\.0\.2\.2|127\.\d+\.\d+\.\d+|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$',
);

Set<String> _words(String text) => text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();

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

const _secondLevels = {'co', 'com', 'org', 'net', 'gov', 'edu', 'ac', 'or', 'ne', 'go'};

final Set<String> _wantedTlds = _words(
  'com net org io co app dev ai info biz xyz tech online cloud site store shop edu gov mil',
);
final Set<String> _needsDepth = _words('app');
final Set<String> _countryTlds = _words('''
  ng ke za gh tz ug et eg ma dz tn sn ci cm uk de fr nl be ch es pt pl cz se dk fi ie gr tr ru ua cn jp kr tw hk sg
  ph vn th au nz ca us mx br ar cl pe ve il ae sa pk bd lk eu
''');
final Set<String> _collidingTlds = _words('id in it is to no me so do at by my as');
final Set<String> _fileExtensions = _words('''
  dart yaml yml json swift kt kts png jpg jpeg gif svg md txt html css js ts tsx jsx py rb rs go sh java cpp xml plist
  gradle lock log pdf zip mov mp4 mp3 wav ttf otf ipa apk aab dylib so dll exe
''');
final Set<String> _glintNames = _words('glint glint_mcp glint_network glint_core');

final Set<String> _genericDeviceWords = _words('''
  iphone ipad ipod pro max plus mini ultra air simulator emulator pixel galaxy android sdk built for gphone phone
  tablet generation gen inch apple watch samsung google xiaomi redmi oneplus huawei motorola sony nokia realme oppo
  vivo honor fold flip lite edge note tab arm x se xl xr the mac desktop chrome web ios cellular wifi wi fi a s ram
  gb tb medium small large resizable nexus vision api foldable automotive wear tv
''');

final Set<String> _stopWords = (() {
  const words = '''
    a an and my new old our the you about above across after again against album also always among another answer anyone anything app apple
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
