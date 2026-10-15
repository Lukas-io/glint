/// One notification the system holds, as `dumpsys notification --noredact` lists it.
class PostedNotification {
  PostedNotification({
    required this.package,
    required this.key,
    required this.id,
    this.title,
    this.text,
    this.actions = const [],
    this.postedAt,
    this.ongoing = false,
    this.channel,
  });

  final String package;
  final String key;
  final int id;
  final String? title;
  final String? text;
  final List<String> actions;
  final DateTime? postedAt;
  final bool ongoing;
  final String? channel;

  Map<String, Object?> toJson() => {
        'package': package,
        if (title != null) 'title': title,
        if (text != null) 'text': text,
        if (actions.isNotEmpty) 'actions': actions,
        if (postedAt != null) 'postedAt': postedAt!.toIso8601String(),
        if (ongoing) 'ongoing': true,
        if (channel != null) 'channel': channel,
        'key': key,
      };

  /// `Amara: Got it 👍 [Reply, Mark as read]`.
  String get line => [
        [title, text].nonNulls.join(': '),
        if (actions.isNotEmpty) '[${actions.join(', ')}]',
      ].join(' ');
}

final _record = RegExp(r'^\s*NotificationRecord\(0x[0-9a-f]+: pkg=(\S+) .*? id=(-?\d+) .*? key=(\S+): Notification\(channel=(\S+) .*?flags=(\S+)');
final _extra = RegExp(r'^\s*android\.(title|text|bigText)=\w*String \((.*)\)\s*$');
final _action = RegExp(r'^\s*\[\d+\] "(.*)" -> ');
final _when = RegExp(r'^\s*when=(\d+)/');

/// The active notifications in a `dumpsys notification --noredact` dump, newest first.
List<PostedNotification> parseNotificationDump(String dump) {
  final out = <PostedNotification>[];
  final lines = dump.split('\n');
  var inList = false;
  Map<String, Object?>? cur;
  void flush() {
    final c = cur;
    if (c == null) return;
    out.add(PostedNotification(
      package: c['pkg']! as String,
      key: c['key']! as String,
      id: c['id']! as int,
      title: c['title'] as String?,
      text: (c['bigText'] ?? c['text']) as String?,
      actions: (c['actions'] as List<String>?) ?? const [],
      postedAt: c['when'] as DateTime?,
      ongoing: (c['flags']! as String).contains('ONGOING'),
      channel: c['channel'] as String?,
    ));
    cur = null;
  }

  for (final line in lines) {
    if (line.trim() == 'Notification List:') {
      inList = true;
      continue;
    }
    if (!inList) continue;
    if (RegExp(r'^  \S').hasMatch(line)) break;
    final r = _record.firstMatch(line);
    if (r != null) {
      flush();
      cur = {'pkg': r[1], 'id': int.parse(r[2]!), 'key': r[3], 'channel': r[4], 'flags': r[5], 'actions': <String>[]};
      continue;
    }
    final c = cur;
    if (c == null) continue;
    final e = _extra.firstMatch(line);
    if (e != null) {
      c.putIfAbsent(e[1]!, () => e[2]);
      continue;
    }
    final a = _action.firstMatch(line);
    if (a != null) {
      (c['actions']! as List<String>).add(a[1]!);
      continue;
    }
    final w = _when.firstMatch(line);
    if (w != null) c['when'] = DateTime.fromMillisecondsSinceEpoch(int.parse(w[1]!));
  }
  flush();
  out.sort((a, b) => (b.postedAt ?? DateTime(0)).compareTo(a.postedAt ?? DateTime(0)));
  return out;
}

/// A notification row as the shade draws it, with the screen rects to touch (physical pixels).
class ShadeRow {
  ShadeRow({required this.bounds, this.title, this.text, this.actions = const {}, this.expand});

  final List<int> bounds;
  final String? title;
  final String? text;

  /// Visible action buttons by label.
  final Map<String, List<int>> actions;

  /// The row's expand button, when its actions are folded away.
  final List<int>? expand;

  ({int x, int y}) get center => (x: (bounds[0] + bounds[2]) ~/ 2, y: (bounds[1] + bounds[3]) ~/ 2);
}

/// The shade's notification rows and its "Clear all" button, read from glint's server `windows` reply.
({List<ShadeRow> rows, List<int>? clearAll}) parseShade(Map<String, Object?> windows) {
  final rows = <ShadeRow>[];
  List<int>? clearAll;
  List<int> rect(Map<String, Object?> n) => [for (final v in (n['bounds'] as List? ?? const [0, 0, 0, 0])) (v as num).toInt()];
  Iterable<Map<String, Object?>> walk(Map<String, Object?> n) sync* {
    yield n;
    for (final c in (n['children'] as List? ?? const [])) {
      yield* walk((c as Map).cast<String, Object?>());
    }
  }

  for (final w in (windows['windows'] as List? ?? const [])) {
    final win = (w as Map).cast<String, Object?>();
    if (win['package'] != 'com.android.systemui') continue;
    final root = (win['root'] as Map?)?.cast<String, Object?>();
    if (root == null) continue;
    for (final n in walk(root)) {
      final id = n['id'] as String? ?? '';
      final text = n['text'] as String?;
      if (clearAll == null && (id.endsWith('clear_all') || id.endsWith('dismiss_text') || text?.toLowerCase() == 'clear all')) {
        clearAll = rect(n);
      }
      if (!id.endsWith('expandableNotificationRow')) continue;
      String? title, body;
      final actions = <String, List<int>>{};
      List<int>? expand;
      for (final d in walk(n)) {
        final did = d['id'] as String? ?? '';
        final t = d['text'] as String?;
        if ((did == 'android:id/title' || did.endsWith(':id/notification_title')) && t != null) title ??= t;
        if ((did == 'android:id/text' || did == 'android:id/big_text' || did.endsWith(':id/notification_text')) && t != null) body ??= t;
        if (did == 'android:id/expand_button') expand = rect(d);
        if ((d['class'] as String? ?? '').endsWith('Button') && t != null && t.isNotEmpty) actions[t] = rect(d);
      }
      rows.add(ShadeRow(bounds: rect(n), title: title, text: body, actions: actions, expand: expand));
    }
  }
  return (rows: rows, clearAll: clearAll);
}

/// The buttons of a permission dialog on screen (Allow, Don't allow), from glint's server `windows` reply.
List<({String label, List<int> bounds})> permissionButtons(Map<String, Object?> windows) {
  final out = <({String label, List<int> bounds})>[];
  void walk(Map<String, Object?> n) {
    final text = n['text'] as String?;
    if ((n['class'] as String? ?? '').endsWith('Button') && text != null) {
      out.add((label: text, bounds: [for (final v in (n['bounds'] as List)) (v as num).toInt()]));
    }
    for (final c in (n['children'] as List? ?? const [])) {
      walk((c as Map).cast<String, Object?>());
    }
  }

  for (final w in (windows['windows'] as List? ?? const [])) {
    final win = (w as Map).cast<String, Object?>();
    if (!'${win['package']}'.contains('permissioncontroller')) continue;
    final root = (win['root'] as Map?)?.cast<String, Object?>();
    if (root != null) walk(root);
  }
  return out;
}

/// A `uiautomator dump` hierarchy in the shape of glint's server `windows` reply, so the shade parsers read either.
Map<String, Object?> uiDumpAsWindows(String xml) {
  final byPackage = <String, Map<String, Object?>>{};
  final stack = <Map<String, Object?>>[];
  final tag = RegExp(r'<node\b([^>]*?)(/?)>|</node>');
  String? attr(String attrs, String name) => RegExp('$name="([^"]*)"').firstMatch(attrs)?.group(1);
  String unescape(String v) => v.replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
  for (final m in tag.allMatches(xml)) {
    if (m.group(0) == '</node>') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    final a = m.group(1)!;
    final b = RegExp(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]').firstMatch(attr(a, 'bounds') ?? '');
    final text = unescape(attr(a, 'text') ?? '');
    final node = <String, Object?>{
      'bounds': b == null ? [0, 0, 0, 0] : [for (var i = 1; i <= 4; i++) int.parse(b.group(i)!)],
      'class': attr(a, 'class'),
      if (text.isNotEmpty) 'text': text,
      if ((attr(a, 'resource-id') ?? '').isNotEmpty) 'id': attr(a, 'resource-id'),
      'children': <Map<String, Object?>>[],
    };
    if (stack.isEmpty) {
      final pkg = attr(a, 'package') ?? '';
      byPackage.putIfAbsent(pkg, () => {'package': pkg, 'root': {'bounds': [0, 0, 0, 0], 'children': <Map<String, Object?>>[]}});
      ((byPackage[pkg]!['root']! as Map)['children']! as List).add(node);
    } else {
      (stack.last['children']! as List).add(node);
    }
    if (m.group(2) != '/') stack.add(node);
  }
  return {'windows': byPackage.values.toList()};
}
