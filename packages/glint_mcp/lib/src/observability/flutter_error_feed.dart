import 'dart:async';

import 'app_log_buffer.dart';

/// One distinct error the app reported, with how often and where.
class FlutterErrorEntry {
  FlutterErrorEntry({
    required this.summary,
    required this.seq,
    required DateTime at,
    this.location,
    this.library,
    this.channel = FlutterErrorChannel.log,
  })  : firstSeen = at,
        lastSeen = at,
        firstSeq = seq,
        _hits = [seq];

  final String summary;

  /// `lib/home.dart:88` for the app's own code, a `package:` path for a dependency, a file path otherwise.
  String? location;
  String? library;
  int count = 1;
  final DateTime firstSeen;
  DateTime lastSeen;
  final int firstSeq;

  /// Feed seq of the latest occurrence.
  int seq;
  FlutterErrorChannel channel;
  final List<int> _hits;

  String get key => '$summary|${location ?? ''}';

  /// `summary (location)` for replies.
  String get line => location == null ? summary : '$summary ($location)';

  /// Occurrences after feed seq [since].
  int countSince(int since) => _hits.where((s) => s > since).length;

  void _hit(int at, DateTime when, FlutterErrorChannel via) {
    seq = at;
    count++;
    lastSeen = when;
    channel = via;
    _hits.add(at);
    if (_hits.length > 200) _hits.removeAt(0);
  }

  Map<String, Object?> toJson({int? since}) => {
        'summary': summary,
        if (location != null) 'location': location,
        if (library != null) 'library': library,
        'count': since == null ? count : countSince(since),
        'firstSeen': firstSeen.toUtc().toIso8601String(),
        'lastSeen': lastSeen.toUtc().toIso8601String(),
        'seq': seq,
      };
}

/// Where an occurrence was read from: Flutter's `Flutter.Error` events or the app's console output.
enum FlutterErrorChannel { structured, log }

/// The distinct errors an app reports, read without any app code: Flutter's structured error events when `flutter run` enabled them, else the error dumps in the app's console output.
class FlutterErrorFeed {
  FlutterErrorFeed({this.capacity = 50, String? Function()? projectDir, String? Function()? packageName})
      : _projectDir = projectDir,
        _packageName = packageName {
    _logs = _Scanner(this, FlutterErrorChannel.log);
  }

  static const summaryLimit = 160;
  static const _crossChannelWindow = Duration(milliseconds: 1500);

  final int capacity;
  final String? Function()? _projectDir;
  final String? Function()? _packageName;
  final Map<String, FlutterErrorEntry> _entries = {};
  final _new = StreamController<FlutterErrorEntry>.broadcast(sync: true);
  late final _Scanner _logs;
  StreamSubscription<AppLogEntry>? _logSub;
  Timer? _idle;
  int _seq = 0;

  /// Seq of the latest occurrence of any error; 0 before the first.
  int get lastSeq => _seq;

  /// Fires once for each error not seen before (by summary and location), never for repeats.
  Stream<FlutterErrorEntry> get onNewError => _new.stream;

  List<FlutterErrorEntry> get all => _entries.values.toList();

  /// Reads the app's console output from [entries], stdout and stderr only.
  void listen(Stream<AppLogEntry> entries) {
    _logSub?.cancel();
    _logSub = entries.listen((e) {
      if (e.stream == AppLogStream.logging) return;
      _logs.add(e.content);
      _idle?.cancel();
      _idle = Timer(const Duration(milliseconds: 400), flush);
    });
  }

  /// Finishes a dump or exception still being read, so everything seen so far is in the feed.
  void flush() {
    _idle?.cancel();
    _logs.flush();
  }

  /// Errors with an occurrence after [seq], oldest first.
  List<FlutterErrorEntry> since(int seq) {
    flush();
    return [
      for (final e in _entries.values)
        if (e.seq > seq) e,
    ]..sort((a, b) => a.firstSeq.compareTo(b.firstSeq));
  }

  /// Reads one `Flutter.Error` extension event.
  void addStructured(Map<String, Object?>? data) {
    if (data == null) return;
    final scanner = _Scanner(this, FlutterErrorChannel.structured, libraryHint: _libraryOf(data['description']));
    final text = data['renderedErrorText'];
    if (text is String && text.trim().isNotEmpty) {
      scanner
        ..add(text)
        ..flush();
      return;
    }
    final summary = _summaryNode(data['properties']);
    if (summary != null) _record(summary, null, scanner.libraryHint, FlutterErrorChannel.structured);
  }

  void dispose() {
    _idle?.cancel();
    _logSub?.cancel();
    _new.close();
  }

  static String? _libraryOf(Object? description) {
    if (description is! String) return null;
    final m = RegExp(r'caught by (.+)$', caseSensitive: false).firstMatch(description.trim());
    return m?.group(1)?.toLowerCase();
  }

  static String? _summaryNode(Object? properties) {
    if (properties is! List) return null;
    for (final p in properties) {
      if (p is Map && p['type'] == 'ErrorSummary' && p['description'] is String) return p['description'] as String;
    }
    return null;
  }

  static String tidy(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > summaryLimit ? '${one.substring(0, summaryLimit - 1)}…' : one;
  }

  void _record(String rawSummary, String? location, String? library, FlutterErrorChannel via) {
    final summary = tidy(rawSummary);
    if (summary.isEmpty) return;
    final now = DateTime.now();
    final existing = _find(summary, location);
    if (existing != null) {
      if (existing.channel != via && now.difference(existing.lastSeen) < _crossChannelWindow) return;
      existing._hit(++_seq, now, via);
      if (existing.location == null && location != null) {
        _entries.remove(existing.key);
        existing.location = location;
        _entries[existing.key] = existing;
      }
      existing.library ??= library;
      return;
    }
    final entry = FlutterErrorEntry(
      summary: summary,
      seq: ++_seq,
      at: now,
      location: location,
      library: library,
      channel: via,
    );
    _entries[entry.key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    if (!_new.isClosed) _new.add(entry);
  }

  FlutterErrorEntry? _find(String summary, String? location) {
    final exact = _entries['$summary|${location ?? ''}'];
    if (exact != null) return exact;
    for (final e in _entries.values.toList().reversed) {
      if (!_sameSummary(e.summary, summary)) continue;
      if (e.location == null || location == null) return e;
    }
    return null;
  }

  static bool _sameSummary(String a, String b) {
    if (a == b) return true;
    final short = a.length < b.length ? a : b;
    final long = identical(short, a) ? b : a;
    return short.length >= 30 && long.startsWith(short);
  }

  String? _relative(String uri, String line) {
    final package = _packageName?.call();
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return '$uri:$line';
      return rest.substring(0, slash) == package ? 'lib/${rest.substring(slash + 1)}:$line' : '$uri:$line';
    }
    final Uri parsed;
    try {
      parsed = Uri.parse(uri);
    } on FormatException {
      return null;
    }
    final path = _canonical(parsed.toFilePath());
    final root = _projectDir?.call();
    if (root != null) {
      final prefix = '${_canonical(root).replaceFirst(RegExp(r'/+$'), '')}/';
      if (path.startsWith(prefix)) return '${path.substring(prefix.length)}:$line';
    }
    return '$path:$line';
  }

  static String _canonical(String path) => path.replaceFirst(RegExp(r'^/private(?=/(tmp|var)/)'), '');

  bool _isOwnFrame(String uri) {
    final package = _packageName?.call();
    if (uri.startsWith('package:')) return package != null && uri.startsWith('package:$package/');
    final root = _projectDir?.call();
    return root != null && _canonical(uri.replaceFirst('file://', '')).startsWith(_canonical(root));
  }
}

final _fileRef = RegExp(r'((?:file://|package:)\S*?\.dart):(\d+)(?::\d+)?');
final _logPrefix = RegExp(r'^(?:[VDIWEF]/flutter\s*\(\s*\d+\):\s?|flutter: )');
final _header = RegExp(r'══╡ EXCEPTION CAUGHT BY (.+?) ╞');
final _rule = RegExp(r'^═{10,}$');
final _thrown = RegExp(r'^The following .* (?:was|were) thrown');
final _unhandled = RegExp(r'Unhandled [Ee]xception:\s*(.*)$');
final _another = RegExp(r'Another exception was thrown:\s*(.*)$');
final _stackLine = RegExp(r'^#\d+\s');

/// Reads text a chunk at a time and reports each error dump, repeat line and uncaught exception in it to [_feed].
class _Scanner {
  _Scanner(this._feed, this._channel, {this.libraryHint});

  static const _maxBlock = 800;
  static const _maxStack = 60;

  final FlutterErrorFeed _feed;
  final FlutterErrorChannel _channel;
  final String? libraryHint;
  String _partial = '';
  List<String>? _block;
  String? _blockLibrary;
  String? _uncaught;
  List<String> _uncaughtStack = [];

  void add(String chunk) {
    _partial += chunk;
    final lines = _partial.split('\n');
    _partial = lines.removeLast();
    lines.forEach(_line);
  }

  void flush() {
    if (_partial.isNotEmpty) {
      final last = _partial;
      _partial = '';
      _line(last);
    }
    _endBlock();
    _endUncaught();
  }

  void _line(String raw) {
    final line = raw.trimRight().replaceFirst(_logPrefix, '');
    if (_block != null) {
      if (_rule.hasMatch(line.trim())) {
        _endBlock();
        return;
      }
      if (_header.hasMatch(line)) {
        _endBlock();
      } else {
        _block!.add(line);
        if (_block!.length > _maxBlock) _endBlock();
        return;
      }
    }
    if (_uncaught != null && _continuesUncaught(line)) return;
    _endUncaught();
    final header = _header.firstMatch(line);
    if (header != null) {
      _block = [];
      _blockLibrary = header.group(1)!.toLowerCase();
      return;
    }
    final another = _another.firstMatch(line);
    if (another != null) {
      _feed._record(another.group(1)!, null, libraryHint, _channel);
      return;
    }
    final unhandled = _unhandled.firstMatch(line);
    if (unhandled != null) {
      _uncaught = unhandled.group(1)!.trim();
      _uncaughtStack = [];
    }
  }

  bool _continuesUncaught(String line) {
    if (line.trim().isEmpty) return true;
    if (_stackLine.hasMatch(line.trim())) {
      if (_uncaughtStack.length < _maxStack) _uncaughtStack.add(line);
      return true;
    }
    if (_uncaught!.isEmpty) {
      _uncaught = line.trim();
      return true;
    }
    return false;
  }

  void _endUncaught() {
    final summary = _uncaught;
    if (summary == null) return;
    final stack = _uncaughtStack;
    _uncaught = null;
    _uncaughtStack = [];
    if (summary.isEmpty) return;
    _feed._record(summary, _frameLocation(stack), 'uncaught', _channel);
  }

  void _endBlock() {
    final lines = _block;
    if (lines == null) return;
    final library = _blockLibrary;
    _block = null;
    _blockLibrary = null;
    final summary = _dumpSummary(lines);
    if (summary == null) return;
    _feed._record(summary, _widgetLocation(lines) ?? _frameLocation(lines), library ?? libraryHint, _channel);
  }

  static String? _dumpSummary(List<String> lines) {
    final at = lines.indexWhere(_thrown.hasMatch);
    var i = at + 1;
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length) return null;
    var summary = lines[i].trim();
    if (summary.length >= 90 && !RegExp(r'[.!?:]$').hasMatch(summary)) {
      for (var j = i + 1; j < lines.length && j <= i + 2; j++) {
        final next = lines[j].trim();
        if (next.isEmpty || next.startsWith('The ') || next.startsWith('When ')) break;
        summary = '$summary $next';
        if (RegExp(r'[.!?:]$').hasMatch(next)) break;
      }
    }
    return summary;
  }

  String? _widgetLocation(List<String> lines) {
    final at = lines.indexWhere((l) => l.trim() == 'The relevant error-causing widget was:');
    if (at < 0) return null;
    for (var i = at + 1; i < lines.length && i <= at + 6; i++) {
      if (lines[i].trim().isEmpty) break;
      final m = _fileRef.firstMatch(lines[i]);
      if (m != null) return _feed._relative(m.group(1)!, m.group(2)!);
    }
    return null;
  }

  String? _frameLocation(List<String> lines) {
    for (final l in lines) {
      if (!_stackLine.hasMatch(l.trim())) continue;
      final m = _fileRef.firstMatch(l);
      if (m != null && _feed._isOwnFrame(m.group(1)!)) return _feed._relative(m.group(1)!, m.group(2)!);
    }
    return null;
  }
}
