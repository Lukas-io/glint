/// Probe A1.1: open a dialog via VM evaluate on a known inner context,
/// then dump the summary tree to confirm where dialog content lands.
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main(List<String> args) async {
  final wsUri = args.isNotEmpty ? _toWs(args[0]) : _toWs('http://127.0.0.1:59347/ugs90HOfhws=/');
  print('Connecting to $wsUri');
  final ws = await vmServiceConnectUri(wsUri);

  final vm = await ws.getVM();
  Isolate? flutter;
  for (final ref in vm.isolates ?? <IsolateRef>[]) {
    if (ref.id == null) continue;
    final iso = await ws.getIsolate(ref.id!);
    if ((iso.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) {
      flutter = iso; break;
    }
  }
  if (flutter == null) { print('No Flutter isolate'); return; }
  final isoId = flutter.id!;
  final rootLibId = flutter.rootLib?.id;
  print('rootLib = ${flutter.rootLib?.uri}');
  if (rootLibId == null) { print('No rootLib'); return; }

  // Step 1: read tree, find a Scaffold widget (has Navigator ancestor).
  final treeResp1 = await ws.callServiceExtension(
    'ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'probe-ctx', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'},
  );
  final tree1 = (treeResp1.json?['result'] as Map?)?.cast<String, Object?>();
  final scaffoldId = _findTypeId(tree1 ?? {}, 'Scaffold');
  print('\nFirst Scaffold inspectorId: $scaffoldId');
  if (scaffoldId == null) { print('No Scaffold found'); return; }

  await ws.callServiceExtension(
    'ext.flutter.inspector.setSelectionById',
    isolateId: isoId,
    args: {'arg': scaffoldId, 'objectGroup': 'probe-ctx'},
  );

  // Step 2: verify selection works and try showDialog from that context.
  print('\n--- eval test (check context) ---');
  try {
    final raw = await ws.evaluate(isoId, rootLibId,
      'ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.settings.name ?? "no-route"');
    if (raw is InstanceRef) print('route = ${raw.valueAsString}');
    else print('eval returned: ${raw.runtimeType}');
  } catch (e) { print('eval threw: $e'); }

  // Step 3: push dialog.
  print('\n--- pushing dialog ---');
  try {
    final raw = await ws.evaluate(isoId, rootLibId,
      'Navigator.of(WidgetInspectorService.instance.selection.currentElement!)'
      '.push(DialogRoute(context: WidgetInspectorService.instance.selection.currentElement!, builder: (_) => AlertDialog(title: Text("probe-open"), content: Text("tree check"))))');
    print('push result: ${raw.runtimeType}');
  } catch (e) { print('push threw: $e'); }

  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Step 4: dump tree with dialog open — this is the core probe.
  print('\n=== SUMMARY TREE WITH DIALOG OPEN ===');
  final treeResp2 = await ws.callServiceExtension(
    'ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'probe-dialog', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'},
  );
  final tree2 = (treeResp2.json?['result'] as Map?)?.cast<String, Object?>();
  if (tree2 == null) { print('No tree result'); }
  else { _dumpNode(tree2, 0, maxDepth: 12); }

  // Clean up.
  try {
    await ws.callServiceExtension('ext.flutter.inspector.disposeGroup',
        isolateId: isoId, args: {'groupName': 'probe-ctx'});
    await ws.callServiceExtension('ext.flutter.inspector.disposeGroup',
        isolateId: isoId, args: {'groupName': 'probe-dialog'});
  } on Object {}

  await ws.dispose();
}

String? _findTypeId(Map<String, Object?> node, String type) {
  final t = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '';
  if (t == type) return node['valueId'] as String?;
  final kids = node['children'];
  if (kids is List) {
    for (final c in kids) {
      if (c is Map) {
        final found = _findTypeId(c.cast<String, Object?>(), type);
        if (found != null) return found;
      }
    }
  }
  return null;
}

void _dumpNode(Map<String, Object?> node, int depth, {int maxDepth = 12}) {
  if (depth > maxDepth) { print('${'  ' * depth}…'); return; }
  final type = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '-';
  final local = node['createdByLocalProject'] == true ? '✓' : '·';
  print('${'  ' * depth}$local $type [$id]');
  final kids = node['children'];
  if (kids is List) {
    for (final c in kids) {
      if (c is Map) _dumpNode(c.cast<String, Object?>(), depth + 1, maxDepth: maxDepth);
    }
  }
}

String _toWs(String u) {
  u = u.replaceFirst('http://', 'ws://');
  if (!u.endsWith('/ws')) u = '${u.endsWith('/') ? u : '$u/'}ws';
  return u;
}
// (not appending — replacing with full+summary comparison version)
