// Probe: can we run a REAL hit-test in an eval (does naming HitTestResult
// still fail), and does the hit-path check correctly report hittability?
//
//   dart run tool/probe_hittest.dart <vm-uri> [needle]

import 'package:glint/glint.dart';
import 'package:glint/perception.dart';

Future<void> main(List<String> args) async {
  final vm = VmServiceRuntime();
  await vm.attach(Uri.parse(args[0]));
  final reader = SceneReader(InspectorClient(vm), vm);
  final scene = await reader.readSummary();

  // Pick a real, user-code, addressable node (a button-ish leaf if possible).
  SceneNode? target;
  final needle = args.length > 1 ? args[1] : null;
  for (final n in scene.root.walk()) {
    if (n.glintId == null || n.inspectorId.isEmpty) continue;
    if (needle != null && !(n.glintId!.contains(needle))) continue;
    if (n.createdByLocalProject) {
      target = n;
      break;
    }
  }
  if (target == null) {
    print('no addressable node found');
    await vm.disconnect();
    return;
  }
  print('target: ${target.label} glintId=${target.glintId}');

  const ro = 'WidgetInspectorService.instance.selection.current!';
  final exprs = <String>[
    'GestureBinding.instance.runtimeType.toString()',
    'HitTestResult().runtimeType.toString()',
    'BoxHitTestResult().runtimeType.toString()',
    'WidgetsBinding.instance.renderViews.length.toString()',
    // real hittability via a BoxHitTestResult, if that subclass is nameable
    '((r) { GestureBinding.instance.hitTest(r, $ro.localToGlobal($ro.paintBounds.center)); '
        'return r.path.any((e) => identical(e.target, $ro)); })(BoxHitTestResult()).toString()',
  ];
  for (final e in exprs) {
    try {
      await vm.setInspectorSelection(
          inspectorId: target.inspectorId, groupName: scene.groupName);
      final r = await vm.evaluate(e);
      print('OK  [$e] => ${r.valueAsString ?? r.kind}');
    } on Object catch (err) {
      final msg = '$err'.split('\n').first;
      print('ERR [${e.substring(0, e.length.clamp(0, 40))}…] => $msg');
    }
  }
  await scene.dispose();
  await vm.disconnect();
}
