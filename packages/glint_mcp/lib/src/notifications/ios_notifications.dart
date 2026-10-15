/// A notification SpringBoard shows, as a banner or a Notification Center cell; [frame] is in screen points.
class ShownNotification {
  ShownNotification({required this.app, required this.frame, this.title, this.body, this.grouped = false});

  /// The app name SpringBoard prints on it, upper-cased as drawn.
  final String app;
  final String? title;
  final String? body;
  final List<double> frame;

  /// The collapsed top of a stack of the app's notifications; a tap expands it rather than opening it.
  final bool grouped;

  ({double x, double y}) get center => (x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2);

  Map<String, Object?> toJson() => {'app': app, if (title != null) 'title': title, if (body != null) 'body': body};

  String get line => [title, body].nonNulls.join(': ');
}

/// A tappable element in SpringBoard's tree.
typedef SpringboardButton = ({String label, List<double> frame});

Iterable<Map<String, Object?>> _walk(Map<String, Object?> n) sync* {
  yield n;
  for (final c in (n['children'] as List? ?? const [])) {
    yield* _walk((c as Map).cast<String, Object?>());
  }
}

List<double> _frame(Map<String, Object?> n) => [
      for (final v in (n['frame'] as List? ?? const [0, 0, 0, 0])) (v as num).toDouble()
    ];

/// Banners and Notification Center cells in a runner `/tree?app=com.apple.springboard` reply, top first.
List<ShownNotification> parseSpringboardNotifications(Map<String, Object?> tree) {
  final root = (tree['app'] as Map?)?.cast<String, Object?>();
  if (root == null) return const [];
  final out = <ShownNotification>[];
  for (final n in _walk(root)) {
    if (n['id'] != 'NotificationShortLookView') continue;
    String? title, body;
    for (final d in _walk(n)) {
      if (d['id'] == 'NotificationTitle') title ??= d['label'] as String?;
      if (d['id'] == 'TextContent.Primary') body ??= d['label'] as String?;
    }
    final label = n['label'] as String? ?? '';
    out.add(ShownNotification(
        app: label.split(', ').first,
        frame: _frame(n),
        title: title,
        body: body,
        grouped: label.contains(', Grouped, ')));
  }
  out.sort((a, b) => a.frame[1].compareTo(b.frame[1]));
  return out;
}

/// Every labelled button in the tree and its alerts, for pressing an action, Clear, or a permission answer.
List<SpringboardButton> springboardButtons(Map<String, Object?> tree) => [
      for (final key in const ['alerts', 'app'])
        for (final r in [if (tree[key] is Map) tree[key], if (tree[key] is List) ...(tree[key] as List)])
          for (final n in _walk((r as Map).cast<String, Object?>()))
            if (n['type'] == 'button' && (n['label'] as String? ?? '').isNotEmpty)
              (label: n['label']! as String, frame: _frame(n)),
    ];

/// The title of the alert SpringBoard shows over the app, if any.
String? springboardAlert(Map<String, Object?> tree) {
  final alerts = tree['alerts'] as List? ?? const [];
  return alerts.isEmpty ? null : ((alerts.first as Map)['label'] as String?);
}
