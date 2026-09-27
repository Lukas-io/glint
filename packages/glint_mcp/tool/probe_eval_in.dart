/// Probe: evaluate one expression, with a widget selected, in a named library.
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(args[0]);
  final ws = await vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString());
  final needle = args[1];
  final libSuffix = args[2];
  final exprs = args.sublist(3);
  final vm = await ws.getVM();
  late Isolate iso;
  for (final ref in vm.isolates!) {
    final i = await ws.getIsolate(ref.id!);
    if ((i.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) iso = i;
  }
  final libId = iso.libraries!.firstWhere((l) => l.uri!.endsWith(libSuffix)).id!;
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
  await ws.callServiceExtension('ext.flutter.inspector.setSelectionById',
      isolateId: iso.id!, args: {'arg': find(tree.json!['result'] as Map), 'objectGroup': 'probe'});
  for (final e in exprs) {
    try {
      final r = await ws.evaluate(iso.id!, libId, e);
      print('sel=${find(tree.json!['result'] as Map)} OK  ${e.length > 70 ? e.substring(0, 70) : e} => ${r is InstanceRef ? r.valueAsString ?? r.classRef?.name : r.json}');
    } on Object catch (err) {
      print('ERR ${e.length > 70 ? e.substring(0, 70) : e} => ${'$err'.split('\n').take(4).join(' | ')}');
    }
  }
  await ws.callServiceExtension('ext.flutter.inspector.disposeGroup', isolateId: iso.id!, args: {'objectGroup': 'probe'});
  await ws.dispose();
}
