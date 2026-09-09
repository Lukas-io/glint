// Probe: does a text node's widget expose a TextSpan recognizer (inline link)?
// Finds the first text node containing <needle>, selects it, and evals
// candidate detection expressions so we get the eval right before wiring it.
//
//   dart run tool/probe_richtext.dart <vm-uri> "Sign in"

import 'package:glint/glint.dart';
import 'package:glint/perception.dart';

Future<void> main(List<String> args) async {
  final vmUri = args[0];
  final needle = args.length > 1 ? args[1] : 'Sign in';
  final vm = VmServiceRuntime();
  await vm.attach(Uri.parse(vmUri));
  final reader = SceneReader(InspectorClient(vm), vm);
  final scene = await reader.readSummary();

  SceneNode? target;
  for (final n in scene.root.walk()) {
    if ((n.textPreview ?? '').contains(needle)) {
      target = n;
      break;
    }
  }
  if (target == null) {
    print('no text node containing "$needle"');
    await vm.disconnect();
    return;
  }
  print('node: label=${target.label} glintId=${target.glintId}');

  const w = 'WidgetInspectorService.instance.selection.currentElement!.widget';
  final exprs = <String>[
    '$w.runtimeType.toString()',
    // one-level: top span self or its direct children carry a recognizer
    '((r) => r is RichText && r.text is TextSpan ? '
        '((r.text as TextSpan).recognizer != null || '
        '((r.text as TextSpan).children?.any((s) => s is TextSpan && s.recognizer != null) ?? false)) '
        ': false)($w).toString()',
    // recursive (visitChildren): ANY descendant span has a recognizer
    '((r) { if (r is! RichText) return false; var found = false; '
        'r.text.visitChildren((s) { if (s is TextSpan && s.recognizer != null) found = true; return true; }); '
        'return found; })($w).toString()',
  ];
  for (final e in exprs) {
    try {
      await vm.setInspectorSelection(
          inspectorId: target.inspectorId, groupName: scene.groupName);
      final r = await vm.evaluateString(e);
      print('OK => $r');
    } on Object catch (err) {
      print('ERR => $err');
    }
  }
  await scene.dispose();
  await vm.disconnect();
}
