import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main(List<String> args) async {
  final wsUri = _toWs(args.isNotEmpty ? args[0] : 'http://127.0.0.1:59347/ugs90HOfhws=/');
  final ws = await vmServiceConnectUri(wsUri);
  final vm = await ws.getVM();
  Isolate? flutter;
  for (final ref in vm.isolates ?? <IsolateRef>[]) {
    if (ref.id == null) continue;
    final iso = await ws.getIsolate(ref.id!);
    if ((iso.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) { flutter = iso; break; }
  }
  final isoId = flutter!.id!;
  final rootLibId = flutter.rootLib?.id!;

  final r = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'g', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  final tree = (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};

  // Find all Scaffolds AND their first child (one level down)
  final items = <(String, String, String)>[]; // (id, desc, parentDesc)
  _collectScaffoldChildren(tree, null, items);
  print('Evaluating isCurrent from scaffold children:');

  for (final (id, childDesc, scaffoldDesc) in items.take(8)) {
    await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': id, 'objectGroup': 'g'});
    try {
      final res = await ws.evaluate(isoId, rootLibId!,
        '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.isCurrent ?? false).toString()');
      final isCurrent = res is InstanceRef ? res.valueAsString : '?';
      // Also get route name
      final nameRes = await ws.evaluate(isoId, rootLibId!,
        '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.settings.name ?? "-")');
      final name = nameRes is InstanceRef ? nameRes.valueAsString : '?';
      print('  [$id] child-of-$scaffoldDesc ($childDesc) → isCurrent=$isCurrent, name=$name');
    } catch (e) { print('  [$id] child-of-$scaffoldDesc → threw: $e'); }
  }

  try { await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'g'}); } on Object {}
  await ws.dispose();
}

void _collectScaffoldChildren(Map<String, Object?> node, String? parentScaffold, List<(String, String, String)> out) {
  final type = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '';
  final kids = node['children'];
  if (type == 'Scaffold') {
    // Add first child of this scaffold
    if (kids is List && kids.isNotEmpty) {
      final firstChild = kids[0] as Map<String, Object?>;
      final childId = firstChild['valueId'] as String? ?? '';
      final childType = firstChild['widgetRuntimeType'] as String? ?? firstChild['description'] as String? ?? '?';
      if (childId.isNotEmpty) out.add((childId, childType, '$type[$id]'));
    }
    // Still recurse into children
    if (kids is List) { for (final c in kids) { if (c is Map) _collectScaffoldChildren(c.cast<String, Object?>(), type, out); } }
  } else {
    if (kids is List) { for (final c in kids) { if (c is Map) _collectScaffoldChildren(c.cast<String, Object?>(), parentScaffold, out); } }
  }
}

String _toWs(String u) {
  u = u.replaceFirst('http://', 'ws://');
  if (!u.endsWith('/ws')) u = '${u.endsWith('/') ? u : '$u/'}ws';
  return u;
}
