// P3 verification gate. Hand-eyeballable: read a running app's scene,
// classify it through Module C, and print the plain-text + (optional)
// JSON form. The "gate" passes when a human reading the output can
// answer "what's on screen?" without consulting the raw Module B dump.
//
//   dart run tool/verify_p3.dart --vm-uri ws://...
//   dart run tool/verify_p3.dart --vm-uri ws://... --format json
//
// Module C is read-only: no device, no platform flag, no backend.

import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('format',
        allowed: ['text', 'json', 'both'], defaultsTo: 'text');
  final opts = parser.parse(argv);

  final vm = VmServiceRuntime();
  await vm.attach(Uri.parse(opts['vm-uri'] as String));
  try {
    final reader = SceneReader(InspectorClient(vm), vm);
    final scene = await reader.readSummary();
    try {
      final semantic = Semanticizer().semanticize(scene);

      final format = opts['format'] as String;
      if (format == 'text' || format == 'both') {
        stdout.writeln('== semantic scene (plain text) ==');
        stdout.writeln(const PlainTextSceneRenderer().render(semantic));
      }
      if (format == 'json' || format == 'both') {
        stdout.writeln('== semantic scene (json) ==');
        stdout.writeln(const JsonSceneRenderer().render(semantic));
      }

      stdout.writeln('\n-- coverage --');
      _coverageLine(semantic);
    } finally {
      await scene.dispose();
    }
  } finally {
    await vm.disconnect();
  }
}

void _coverageLine(SemanticScene scene) {
  final counts = <SemanticRole, int>{};
  for (final n in scene.root.walk()) {
    counts.update(n.role, (v) => v + 1, ifAbsent: () => 1);
  }
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln(entries.map((e) => '${e.key.name}=${e.value}').join('  '));
}
