// CLI: attach to a running Flutter app and dump its perception scene.
//
//   dart run tool/perceive.dart --vm-uri ws://127.0.0.1:PORT/TOKEN/ws
//   dart run tool/perceive.dart --vm-uri ... --depth full
//
// --depth summary (default) reads the user-code-only tree.
// --depth full reads the entire element tree.
//
// This is the P1 verification surface — what the agent will eventually see
// (modulo P3's semantic compression).

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('depth',
        allowed: ['summary', 'full'], defaultsTo: 'summary')
    ..addOption('format', allowed: ['tree', 'json'], defaultsTo: 'tree')
    ..addFlag('help', abbr: 'h', negatable: false);
  final opts = parser.parse(args);
  if (opts.flag('help')) {
    stdout.writeln('glint perceive — dump the live perception scene.');
    stdout.writeln(parser.usage);
    return;
  }

  final vm = VmServiceRuntime();
  try {
    await vm.attach(Uri.parse(opts['vm-uri'] as String));
  } on Object catch (e) {
    stderr.writeln('attach failed: $e');
    exit(1);
  }
  stderr.writeln('attached to ${vm.attachedUri}');
  stderr.writeln('flutter isolate id: ${vm.flutterIsolateId}');

  final reader = SceneReader(InspectorClient(vm));
  final scene = (opts['depth'] as String) == 'full'
      ? await reader.readFull()
      : await reader.readSummary();

  try {
    if ((opts['format'] as String) == 'json') {
      stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(scene.root.toJson()));
    } else {
      _printTree(scene.root);
    }
  } finally {
    await scene.dispose();
    await vm.disconnect();
  }
}

void _printTree(SceneNode node, {String prefix = '', bool isLast = true}) {
  final connector = node.depth == 0 ? '' : (isLast ? '└─ ' : '├─ ');
  final label = node.label;
  final id = node.glintId;
  final preview = node.textPreview;
  final localTag = node.createdByLocalProject ? ' [local]' : '';
  stdout.writeln(
    '$prefix$connector$label${id == null ? '' : '  ($id)'}'
    '${preview == null ? '' : '  "${_escape(preview)}"'}'
    '$localTag',
  );
  final childPrefix = node.depth == 0
      ? ''
      : prefix + (isLast ? '   ' : '│  ');
  for (var i = 0; i < node.children.length; i++) {
    _printTree(
      node.children[i],
      prefix: childPrefix,
      isLast: i == node.children.length - 1,
    );
  }
}

String _escape(String s) => s
    .replaceAll('\\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll('"', r'\"');
