/// The kinds of alert a watch can ask for; `terminated` also covers the `disconnected` and `reconnected` events around it.
enum AlertKind {
  error,
  uncaught,
  overflow,
  http,
  terminated;

  /// The kinds `{errors:true}` stands for.
  static const errorKinds = {AlertKind.error, AlertKind.uncaught, AlertKind.overflow};

  static AlertKind? named(String name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// One thing an app reported: [name] is the event's `alert` field, [group] the [AlertKind] a watch selects it by.
class AppAlert {
  const AppAlert(this.group, this.name, this.matched, [this.fields = const {}]);

  final AlertKind group;
  final String name;

  /// One line saying what happened, for the event's `matched` field and reply lines.
  final String matched;
  final Map<String, Object?> fields;
}

/// How far a render object overflowed, read from the framework's `A RenderFlex overflowed by 42 pixels on the bottom.` message.
class OverflowInfo {
  const OverflowInfo(this.renderObject, this.edges);

  final String renderObject;
  final List<({num amount, String edge})> edges;

  num get amount => edges.first.amount;
  String get edge => edges.first.edge;

  static final _message = RegExp(r'^A (\w+) overflowed by (.+?)\.?$');
  static final _edge = RegExp(r'(\d+(?:\.\d+)?) pixels? on the (left|top|bottom|right)');

  static OverflowInfo? parse(String summary) {
    final m = _message.firstMatch(summary.trim());
    if (m == null) return null;
    final edges = [
      for (final e in _edge.allMatches(m.group(2)!)) (amount: _number(e.group(1)!), edge: e.group(2)!),
    ];
    return edges.isEmpty ? null : OverflowInfo(m.group(1)!, edges);
  }

  static num _number(String s) {
    final d = double.parse(s);
    return d == d.roundToDouble() ? d.round() : d;
  }

  Map<String, Object?> toJson() => {
        'renderObject': renderObject,
        'amount': amount,
        'edge': edge,
        if (edges.length > 1)
          'edges': [
            for (final e in edges) {'amount': e.amount, 'edge': e.edge}
          ],
      };
}
