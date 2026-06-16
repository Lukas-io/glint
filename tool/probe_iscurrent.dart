/// Probe G2: check ModalRoute.of(el)?.isCurrent for each Scaffold.
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
  final isoId = flutter!.id!;
  final rootLibId = flutter.rootLib?.id!;

  final r = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'g-iscurrent', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  final tree = (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};

  final scaffolds = <Map<String, Object?>>[];
  _findByType(tree, 'Scaffold', scaffolds);
  print('Found ${scaffolds.length} Scaffold(s)');

  for (final s in scaffolds) {
    final id = s['valueId'] as String? ?? '';
    final desc = s['description'] ?? s['widgetRuntimeType'] ?? '?';
    if (id.isEmpty) continue;
    await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': id, 'objectGroup': 'g-iscurrent'});
    try {
      final res = await ws.evaluate(isoId, rootLibId!,
        '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!) ?? '
        '  ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!.findAncestorStateOfType<NavigatorState>()!.context))'
        '?.isCurrent.toString() ?? "null"');
      if (res is InstanceRef) print('  [$id] $desc → isCurrent: ${res.valueAsString}');
    } catch (e) { print('  [$id] $desc → threw: $e'); }
  }

  try { await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'g-iscurrent'}); } on Object {}
  await ws.dispose();
}

void _findByType(Map<String, Object?> node, String type, List<Map<String, Object?>> results) {
  final t = node['widgetRuntimeType'] as String? ?? node['description'] as String? ?? '';
  if (t == type) results.add(node);
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) _findByType(c.cast<String, Object?>(), type, results); } }
}

String _toWs(String u) {
  u = u.replaceFirst('http://', 'ws://');
  if (!u.endsWith('/ws')) u = '${u.endsWith('/') ? u : '$u/'}ws';
  return u;
}
