/// Probe A1.1: dump getRootWidgetTree structure with and without an overlay.
/// Run while an overlay (dialog/sheet/date-picker) is open to see exactly
/// where the dialog content lives relative to the Scaffold.
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

void main(List<String> args) async {
  final wsUri = args.isNotEmpty
      ? args[0].replaceFirst('http://', 'ws://') + 'ws'
      : 'ws://127.0.0.1:59347/ugs90HOfhws=/ws';

  print('Connecting to $wsUri');
  final ws = await vmServiceConnectUri(wsUri);

  final vm = await ws.getVM();
  Isolate? flutterIsolate;
  for (final ref in vm.isolates ?? <IsolateRef>[]) {
    if (ref.id == null) continue;
    final iso = await ws.getIsolate(ref.id!);
    if ((iso.extensionRPCs ?? []).any((e) => e.startsWith('ext.flutter.'))) {
      flutterIsolate = iso;
      break;
    }
  }
  if (flutterIsolate == null) { print('No Flutter isolate'); return; }
  final isoId = flutterIsolate.id!;
  print('rootLib.uri = ${flutterIsolate.rootLib?.uri}');

  // Read summary tree.
  final resp = await ws.callServiceExtension(
    'ext.flutter.inspector.getRootWidgetTree',
    isolateId: isoId,
    args: {
      'groupName': 'probe-group',
      'isSummaryTree': 'true',
      'withPreviews': 'true',
      'fullDetails': 'false',
    },
  );
  final result = (resp.json?['result'] as Map?)?.cast<String, Object?>();
  if (result == null) { print('No result'); return; }

  print('\n=== SUMMARY TREE (isSummaryTree=true) ===');
  _dumpNode(result, 0, maxDepth: 12);

  try {
    await ws.callServiceExtension(
      'ext.flutter.inspector.disposeGroup',
      isolateId: isoId,
      args: {'groupName': 'probe-group'},
    );
  } on Object {}

  await ws.dispose();
}

void _dumpNode(Map<String, Object?> node, int depth, {int maxDepth = 10}) {
  if (depth > maxDepth) {
    print('${'  ' * depth}... (truncated)');
    return;
  }
  final type = node['widgetRuntimeType'] as String? ??
      node['description'] as String? ?? '?';
  final id = node['valueId'] as String? ?? '-';
  final local = node['createdByLocalProject'] == true ? '✓' : '·';
  final preview = node['textPreview'] as String? ?? '';
  final previewStr = preview.isNotEmpty ? ' "$preview"' : '';
  print('${'  ' * depth}$local $type [$id]$previewStr');

  final children = node['children'];
  if (children is List) {
    for (final c in children) {
      if (c is Map) _dumpNode(c.cast<String, Object?>(), depth + 1, maxDepth: maxDepth);
    }
  }
}
