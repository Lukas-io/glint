/// Compare full vs summary tree when a dialog is open.
/// Answers: does dialog content appear in summary? In full? Where exactly?
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main(List<String> args) async {
  final wsUri = args.isNotEmpty ? _toWs(args[0]) : _toWs('http://127.0.0.1:59347/ugs90HOfhws=/');
  final ws = await vmServiceConnectUri(wsUri);

  final vm = await ws.getVM();
  Isolate? flutter;
  for (final ref in vm.isolates ?? <IsolateRef>[]) {
    if (ref.id == null) continue;
    final iso = await ws.getIsolate(ref.id!);
    if ((iso.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) { flutter = iso; break; }
  }
  if (flutter == null) { print('No Flutter isolate'); return; }
  final isoId = flutter.id!;
  final rootLibId = flutter.rootLib?.id!;

  // Open a dialog first.
  final tree0 = await _readTree(ws, isoId, 'g0', summary: true);
  final scaffoldId = _findTypeId(tree0, 'Scaffold');
  if (scaffoldId == null) { print('No Scaffold'); return; }
  await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': scaffoldId, 'objectGroup': 'g0'});
  try {
    await ws.evaluate(isoId, rootLibId!,
      'Navigator.of(WidgetInspectorService.instance.selection.currentElement!)'
      '.push(DialogRoute(context: WidgetInspectorService.instance.selection.currentElement!, builder: (_) => AlertDialog(title: Text("probe-dialog"))))');
  } catch (e) { print('push: $e'); }
  await Future<void>.delayed(const Duration(milliseconds: 600));

  // Read both summary and full trees.
  final summary = await _readTree(ws, isoId, 'g-summary', summary: true);
  final full    = await _readTree(ws, isoId, 'g-full',    summary: false);

  print('\n=== SUMMARY TREE (probe-dialog present?) ===');
  _dumpFiltered(summary, 0, needle: {'AlertDialog', 'Dialog', 'probe'});
  print('\n=== FULL TREE: nodes containing "AlertDialog" or "Dialog" ===');
  _findAndPrint(full, 0, needle: {'AlertDialog', 'Dialog', '_DialogFullscreenRoute', 'DialogRoute', '_ModalBarrier', 'ModalBarrier', 'Overlay', 'OverlayEntry', '_OverlayEntry'});

  for (final g in ['g0', 'g-summary', 'g-full']) {
    try { await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': g}); } on Object {}
  }
  await ws.dispose();
}

Future<Map<String, Object?>> _readTree(VmService ws, String isoId, String g, {required bool summary}) async {
  final r = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
      isolateId: isoId,
      args: {'groupName': g, 'isSummaryTree': summary.toString(), 'withPreviews': 'false', 'fullDetails': 'false'});
  return (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};
}

String? _findTypeId(Map<String, Object?> node, String type) {
  if ((node['widgetRuntimeType'] ?? node['description']) == type) return node['valueId'] as String?;
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) { final f = _findTypeId(c.cast<String, Object?>(), type); if (f != null) return f; } } }
  return null;
}

bool _nodeMatches(Map<String, Object?> node, Set<String> needle) {
  final t = (node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '').toLowerCase();
  return needle.any((n) => t.contains(n.toLowerCase()));
}

void _dumpFiltered(Map<String, Object?> node, int depth, {required Set<String> needle}) {
  final type = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '-';
  if (_nodeMatches(node, needle)) {
    print('${'  ' * depth}MATCH → $type [$id]');
  }
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) _dumpFiltered(c.cast<String, Object?>(), depth + 1, needle: needle); } }
}

void _findAndPrint(Map<String, Object?> node, int depth, {required Set<String> needle}) {
  final type = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '-';
  final local = node['createdByLocalProject'] == true ? '✓' : '·';
  if (_nodeMatches(node, needle)) {
    print('${'  ' * depth}$local $type [$id]');
  }
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) _findAndPrint(c.cast<String, Object?>(), depth + 1, needle: needle); } }
}

String _toWs(String u) {
  u = u.replaceFirst('http://', 'ws://');
  if (!u.endsWith('/ws')) u = '${u.endsWith('/') ? u : '$u/'}ws';
  return u;
}
