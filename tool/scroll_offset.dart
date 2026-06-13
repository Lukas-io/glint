// Throwaway helper: read the fixture's current scroll offset via the
// `glintReadScrollOffset` top-level helper added in main.dart. Used
// during P2.2 to verify swipe scrolls the SingleChildScrollView.
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final svc = await vmServiceConnectUri(_ws(Uri.parse(args[0])));
  final vm = await svc.getVM();
  Isolate? flutter;
  for (final ref in vm.isolates ?? const <IsolateRef>[]) {
    final i = await svc.getIsolate(ref.id!);
    if ((i.extensionRPCs ?? const []).any((e) => e.startsWith('ext.flutter.'))) {
      flutter = i;
      break;
    }
  }
  final result = await svc.evaluate(
      flutter!.id!, flutter.rootLib!.id!, 'glintReadScrollOffset()');
  print((result as InstanceRef).valueAsString);
  await svc.dispose();
}

String _ws(Uri u) {
  if (u.scheme == 'ws' || u.scheme == 'wss') return u.toString();
  final segs = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (segs.isEmpty || segs.last != 'ws') segs.add('ws');
  return Uri(scheme: u.scheme == 'https' ? 'wss' : 'ws', host: u.host, port: u.port, pathSegments: segs).toString();
}
