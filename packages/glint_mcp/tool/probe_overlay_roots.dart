/// Probe: print what the scene reader classifies as overlay content on the current screen.
import 'package:glint_mcp/glint.dart';
import 'package:glint_mcp/perception.dart';

Future<void> main(List<String> args) async {
  final vm = VmServiceRuntime();
  await vm.attach(Uri.parse(args[0]));
  final scene = await SceneReader(InspectorClient(vm), vm).readSummary();
  print('overlayRoots=${scene.overlayRoots.length} barrier=${scene.hasBarrierOverlay}');
  for (final r in scene.overlayRoots) {
    print('--- ${r.label}');
    for (final n in r.walk().take(25)) {
      print('${'  ' * (n.depth - r.depth)}${n.label} ${n.glintId ?? ''} ${n.textPreview ?? ''}');
    }
  }
  await scene.dispose();
  await vm.disconnect();
}
