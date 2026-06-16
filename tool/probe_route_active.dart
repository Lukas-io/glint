/// Probe G2 attempt 2: try different APIs to detect the active GoRouter route.
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
    args: {'groupName': 'g-route', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  final tree = (r.json?['result'] as Map?)?.cast<String, Object?>() ?? {};

  // Try each Scaffold's FIRST CHILD instead of the scaffold itself
  final scaffolds = <Map<String, Object?>>[];
  _findByType(tree, 'Scaffold', scaffolds);

  for (final s in scaffolds) {
    final id = s['valueId'] as String? ?? '';
    final desc = s['description'] ?? s['widgetRuntimeType'] ?? '?';
    if (id.isEmpty) continue;
    
    // Try the scaffold itself first
    await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': id, 'objectGroup': 'g-route'});

    // Try several APIs
    for (final (label, expr) in [
      ('isCurrent via ModalRoute', '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.isCurrent ?? "null").toString()'),
      ('focus scope', 'FocusScope.of(WidgetInspectorService.instance.selection.currentElement!).isFirstFocus.toString()'),
      ('focusedChild', 'FocusScope.of(WidgetInspectorService.instance.selection.currentElement!).hasFocus.toString()'),
      ('primaryFocus match', '(FocusManager.instance.primaryFocus?.context?.findRenderObject() == WidgetInspectorService.instance.selection.current).toString()'),
      ('paintBounds non-zero', 'WidgetInspectorService.instance.selection.current?.paintBounds.isEmpty.toString()'),
    ]) {
      try {
        final res = await ws.evaluate(isoId, rootLibId!, expr);
        if (res is InstanceRef) print('  [$id] $desc → $label: ${res.valueAsString}');
      } catch (e) { /* skip */ }
    }
  }

  // Also probe GoRouter directly
  print('\n--- GoRouter state ---');
  final any = _firstId(tree);
  if (any != null) {
    await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: isoId, args: {'arg': any, 'objectGroup': 'g-route'});
    for (final (label, expr) in [
      ('GoRouter uri', 'GoRouter.of(WidgetInspectorService.instance.selection.currentElement!, listen: false).routeInformationProvider.value.uri.toString()'),
      ('GoRouter current location', 'GoRouter.of(WidgetInspectorService.instance.selection.currentElement!, listen: false).state?.uri.path ?? "null"'),
    ]) {
      try {
        final res = await ws.evaluate(isoId, rootLibId!, expr);
        if (res is InstanceRef) print('  $label: ${res.valueAsString}');
      } catch (e) { print('  $label: threw $e'); }
    }
  }

  try { await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: isoId, args: {'groupName': 'g-route'}); } on Object {}
  await ws.dispose();
}

String? _firstId(Map<String, Object?> node) {
  final id = node['valueId'] as String?;
  if (id != null && id.isNotEmpty) return id;
  final kids = node['children'];
  if (kids is List) { for (final c in kids) { if (c is Map) { final f = _firstId(c.cast<String, Object?>()!); if (f != null) return f; } } }
  return null;
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
