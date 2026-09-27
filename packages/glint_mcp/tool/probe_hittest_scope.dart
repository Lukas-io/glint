/// Probe: a real hit test evaluated in the gestures library, with the target passed in through eval scope.
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(args[0]);
  final ws = await vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString());
  final needle = args.length > 1 ? args[1] : 'Checkbox';
  final vm = await ws.getVM();
  late Isolate iso;
  for (final ref in vm.isolates!) {
    final i = await ws.getIsolate(ref.id!);
    if ((i.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) iso = i;
  }
  String lib(String suffix) =>
      iso.libraries!.firstWhere((l) => l.uri!.endsWith(suffix)).id!;
  final widgetsLib = lib('flutter/src/widgets/widget_inspector.dart');
  final gesturesLib = lib('flutter/src/gestures/binding.dart');

  final tree = await ws.callServiceExtension('ext.flutter.inspector.getRootWidgetTree',
      isolateId: iso.id!,
      args: {'groupName': 'probe', 'isSummaryTree': 'true', 'withPreviews': 'false', 'fullDetails': 'false'});
  String? find(Map n) {
    if (n['description'] == needle) return n['valueId'] as String?;
    for (final c in (n['children'] as List? ?? const [])) {
      final f = find(c as Map);
      if (f != null) return f;
    }
    return null;
  }
  final id = find(tree.json!['result'] as Map);
  print('target $needle inspectorId=$id');
  await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: iso.id!, args: {'arg': id, 'objectGroup': 'probe'});

  Future<InstanceRef?> ev(String libId, String expr, [Map<String, String>? scope]) async {
    try {
      final r = await ws.evaluate(iso.id!, libId, expr, scope: scope);
      if (r is InstanceRef) return r;
      print('  non-instance: ${r.json}');
    } on Object catch (e) {
      print('  ERR ${'$e'.split('\n').take(3).join(' | ')}');
    }
    return null;
  }

  final ro = await ev(widgetsLib, 'WidgetInspectorService.instance.selection.current!');
  final pt = await ev(widgetsLib,
      'WidgetInspectorService.instance.selection.current!.localToGlobal(WidgetInspectorService.instance.selection.current!.paintBounds.center)');
  final view = await ev(widgetsLib, 'View.of(WidgetInspectorService.instance.selection.currentElement!).viewId');
  print('ro=${ro?.classRef?.name} pt=${pt?.valueAsString} view=${view?.valueAsString}');

  for (final expr in [
    'GestureBinding.instance.runtimeType.toString()',
    'HitTestResult().runtimeType.toString()',
    "((HitTestResult r) => (GestureBinding.instance..hitTestInView(r, p, ${view?.valueAsString ?? 0})).runtimeType.toString() + ' ' + r.path.any((e) => identical(e.target, t)).toString() + ' ' + r.path.take(4).map((e) => e.target.runtimeType.toString()).join('>'))(HitTestResult())",
    "((HitTestResult r) => (GestureBinding.instance..hitTestInView(r, p, ${view?.valueAsString ?? 0})).runtimeType.toString() + ' ' + ((r.path.first.target as dynamic).debugCreator).toString())(HitTestResult())",
  ]) {
    final r = await ev(gesturesLib, expr, {'t': ro!.id!, 'p': pt!.id!});
    print('OK? [${expr.substring(0, expr.length.clamp(0, 60))}] => ${r?.valueAsString}');
  }
  await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: iso.id!, args: {'objectGroup': 'probe'});
  await ws.dispose();
}
