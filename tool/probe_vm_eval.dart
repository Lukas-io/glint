// Helper for verify scripts: connect to a VM URI, eval one expression,
// disconnect. Used by verify_app_errors.dart to trigger log + error
// emissions without going through glint.
//
//   dart run tool/probe_vm_eval.dart <vm-uri> '<expression>'

import 'package:glint/glint.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    print('usage: dart run tool/probe_vm_eval.dart <vm-uri> "<expression>"');
    return;
  }
  final vm = VmClient();
  await vm.attach(Uri.parse(args[0]));
  final rootLib = vm.flutterIsolate.rootLib?.id;
  if (rootLib == null) {
    throw StateError('flutter isolate has no rootLib');
  }
  final result = await vm.service.evaluate(
    vm.flutterIsolateId,
    rootLib,
    args[1],
  );
  print('result: $result');
  await vm.disconnect();
}
