// CLI: resolve a glintId to live coordinates.
//
//   dart run tool/resolve.dart --vm-uri ws://... --id floating_action_button
//
// Used during P1 to verify CoordinateResolver against real apps.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('id', mandatory: true);
  final opts = parser.parse(args);

  final vm = VmClient();
  await vm.attach(Uri.parse(opts['vm-uri'] as String));
  final inspector = InspectorClient(vm);
  final reader = SceneReader(inspector);
  final scene = await reader.readSummary();
  try {
    final resolver = CoordinateResolver(vm);
    final res = await resolver.resolve(scene, opts['id'] as String);
    stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(res.toJson()));
  } finally {
    await scene.dispose();
    await vm.disconnect();
  }
}
