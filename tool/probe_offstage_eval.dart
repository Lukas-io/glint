/// Probe G1 diagnosis: for each Scaffold in the summary tree, evaluate
/// findAncestorWidgetOfExactType<Offstage>() and also check Visibility.
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

  // Read summary tree
  final r = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {'groupName': 'g-eval', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  final tree = (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};

  // Find all Scaffold nodes
  final scaffolds = <Map<String, Object?>>[];
  _findByType(tree, 'Scaffold', scaffolds);
  print('Found ${scaffolds.length} Scaffold node(s)');

  for (final s in scaffolds) {
    final id = s['valueId'] as String? ?? '';
    final desc = s['description'] ?? s['widgetRuntimeType'] ?? '?';
    if (id.isEmpty) { print('  $desc: no valueId'); continue; }

    await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': id, 'objectGroup': 'g-eval'});

    // Check Offstage ancestor
    try {
      final res = await ws.evaluate(isoId, rootLibId!,
        '(WidgetInspectorService.instance.selection.currentElement!'
        '.findAncestorWidgetOfExactType<Offstage>()?.offstage ?? false).toString()');
      if (res is InstanceRef) print('  [$id] $desc → offstage ancestor: ${res.valueAsString}');
      else print('  [$id] $desc → eval returned ${res.runtimeType}');
    } catch (e) { print('  [$id] $desc → eval threw: $e'); }

    // Also check Visibility ancestor
    try {
      final res = await ws.evaluate(isoId, rootLibId!,
        '(WidgetInspectorService.instance.selection.currentElement!'
        '.findAncestorWidgetOfExactType<Visibility>()?.visible ?? true).toString()');
      if (res is InstanceRef) print('  [$id] $desc → visibility ancestor visible: ${res.valueAsString}');
    } catch (e) { print('  [$id] $desc → visibility eval threw: $e'); }

    // Check if paint bounds are NaN
    try {
      final res = await ws.evaluate(isoId, rootLibId!,
        '(WidgetInspectorService.instance.selection.current?.paintBounds.toString() ?? "null")');
      if (res is InstanceRef) print('  [$id] $desc → paintBounds: ${res.valueAsString}');
    } catch (e) { print('  [$id] $desc → paintBounds eval threw: $e'); }
  }

  try { await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'g-eval'}); } on Object {}
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
