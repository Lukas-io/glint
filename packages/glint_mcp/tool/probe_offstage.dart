/// Probe G1: look for Offstage/IndexedStack in full and summary trees.
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

  // Summary tree - search for Offstage / IndexedStack
  final r = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'probe-offstage', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  final tree = (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};
  print('=== Summary tree: nodes with Offstage or IndexedStack ===');
  _findAndPrint(tree, 0, {'Offstage', 'IndexedStack', 'Padding'});

  // Also check full tree briefly for context
  print('\n=== Full tree: Offstage + IndexedStack nodes (for structure) ===');
  final r2 = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'probe-offstage-full', 'isSummaryTree': 'false', 'withPreviews': 'false', 'fullDetails': 'false'});
  final full = (r2.json?['result'] as Map?)?.cast<String, Object?>() ?? {};
  _findAndPrint(full, 0, {'Offstage', 'IndexedStack'});

  try {
    await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'probe-offstage'});
    await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'probe-offstage-full'});
  } on Object {}
  await ws.dispose();
}

void _findAndPrint(Map<String, Object?> node, int depth, Set<String> needle) {
  final type = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '-';
  final local = node['createdByLocalProject'] == true ? '✓' : '·';
  if (needle.any((n) => type.contains(n))) {
    print('${'  ' * depth}$local $type [$id]');
  }
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) _findAndPrint(c.cast<String, Object?>(), depth + 1, needle); } }
}

String _toWs(String u) {
  u = u.replaceFirst('http://', 'ws://');
  if (!u.endsWith('/ws')) u = '${u.endsWith('/') ? u : '$u/'}ws';
  return u;
}
