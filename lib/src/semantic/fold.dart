import 'semantic_node.dart';

/// Structural fingerprint of a subtree: what a node IS, not what it says.
/// Two list rows with different text but the same shape share a signature;
/// a row whose toggle state differs, or that lacks a button, does not.
String structuralSignature(SemanticNode node) {
  final b = StringBuffer(node.role.name);
  final affs = node.affordances.map((a) => a.name).toList()..sort();
  if (affs.isNotEmpty) b.write('[${affs.join(',')}]');
  switch (node) {
    case SemanticContainer c:
      b.write(':${c.hint ?? ''}');
    case SemanticButton bt:
      b
        ..write(bt.label != null ? ':L' : ':')
        ..write(bt.isToggle ? 'T' : '')
        ..write(bt.toggleState ?? '');
    case SemanticInput i:
      b
        ..write(i.hint != null ? ':H' : ':')
        ..write((i.currentValue?.isNotEmpty ?? false) ? 'V' : '')
        ..write(i.error != null ? 'E' : '');
    case SemanticUnknown u:
      b.write(':${u.label}');
    default:
      break;
  }
  if (node.children.isNotEmpty) {
    b.write('(');
    for (final c in node.children) {
      b
        ..write(structuralSignature(c))
        ..write(',');
    }
    b.write(')');
  }
  return b.toString();
}

/// A run of consecutive siblings that share a [structuralSignature].
class FoldRun {
  const FoldRun({required this.start, required this.length, required this.signature});

  final int start;
  final int length;
  final String signature;

  int get end => start + length;
}

/// The run starting at [start] when at least [threshold] consecutive siblings
/// share a signature; null otherwise.
FoldRun? detectFoldRun(List<SemanticNode> children, int start,
    {int threshold = 4}) {
  if (start >= children.length) return null;
  final sig = structuralSignature(children[start]);
  var end = start + 1;
  while (end < children.length && structuralSignature(children[end]) == sig) {
    end++;
  }
  final length = end - start;
  if (length < threshold) return null;
  return FoldRun(start: start, length: length, signature: sig);
}

/// What a folded item is called in the digest: its first text, else its first
/// button label, else its first input value. Null when it says nothing.
String? foldItemLabel(SemanticNode item, {int maxChars = 24}) {
  for (final d in item.walk()) {
    String? raw;
    if (d is SemanticText && d.content.trim().isNotEmpty) raw = d.content;
    if (d is SemanticButton && d.label != null && d.label!.trim().isNotEmpty) {
      raw = d.label;
    }
    if (d is SemanticInput && (d.currentValue?.isNotEmpty ?? false)) {
      raw = d.currentValue;
    }
    if (raw == null) continue;
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= maxChars ? flat : '${flat.substring(0, maxChars - 1)}…';
  }
  return null;
}

/// `base#hash` → `base`; unchanged when there is no hash.
String glintIdBase(String id) {
  final i = id.indexOf('#');
  return i < 0 ? id : id.substring(0, i);
}

/// The short address shown in a digest: `#hash` when the item shares the
/// run's base, otherwise the full id.
String? foldItemRef(SemanticNode item, String? runBase) {
  final id = item.glintId;
  if (id == null) return null;
  if (runBase != null && glintIdBase(id) == runBase && id.contains('#')) {
    return id.substring(id.indexOf('#'));
  }
  return id;
}

/// One folded run as the renderer reports it: enough for the trailer and for
/// the eager-list check (which resolves [lastItemId]).
class FoldedRun {
  const FoldedRun({
    required this.base,
    required this.count,
    required this.listId,
    required this.firstItemId,
    required this.lastItemId,
  });

  /// Shared id base of the run's items (e.g. `row_in_transaction_history_screen`).
  final String base;

  /// Items in the run, including the one rendered in full.
  final int count;

  /// glintId of the nearest enclosing list, when the run sits inside one.
  final String? listId;

  final String? firstItemId;
  final String? lastItemId;

  Map<String, Object?> toJson() => {
        'base': base,
        'count': count,
        if (listId != null) 'list': listId,
        if (lastItemId != null) 'lastItemId': lastItemId,
      };
}

/// The digest entries for the folded tail of a run (everything after the first
/// item): `"label" #hash` pairs, at most [max], then `+N`.
String foldDigest(List<SemanticNode> items, String? runBase, {int max = 10}) {
  final parts = <String>[];
  for (final item in items.take(max)) {
    final label = foldItemLabel(item);
    final ref = foldItemRef(item, runBase);
    if (label == null && ref == null) continue;
    parts.add([if (label != null) '"$label"', if (ref != null) ref].join(' '));
  }
  final rest = items.length - max;
  if (rest > 0) parts.add('+$rest');
  return parts.join(', ');
}
