// CLI: drive one action through the full Module B + Module A stack.
//
//   dart run tool/act.dart \
//     --vm-uri ws://... \
//     --platform ios|android \
//     --device <udid|emulator-serial> \
//     tap <glintId>
//
//   dart run tool/act.dart ... swipe <fromGlintId> <toGlintId>
//   dart run tool/act.dart ... press home|back|lock|volumeUp|volumeDown
//
// Reads the scene, resolves the glintId, dispatches through the right
// backend, prints the structured ActionResult as pretty-printed JSON.
// Exit code 0 on ok, 1 on failure.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('platform', allowed: ['ios', 'android'], mandatory: true)
    ..addOption('device', mandatory: true,
        help: 'UDID (iOS) or adb serial (Android)')
    ..addOption('ios-bridge',
        defaultsTo: 'native/ios_sim_bridge/.build/debug/glint-iossim',
        help: 'Path to compiled glint-iossim binary (iOS only)')
    ..addOption('adb-path', defaultsTo: 'adb')
    ..addFlag('refuse-not-hittable', defaultsTo: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults opts;
  try {
    opts = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }
  if (opts.flag('help') || opts.rest.isEmpty) {
    stdout.writeln('Drive one action against a running Flutter app.');
    stdout.writeln(parser.usage);
    stdout.writeln('\nCommands:');
    stdout.writeln('  tap <glintId>');
    stdout.writeln('  swipe <fromGlintId> <toGlintId>');
    stdout.writeln('  press <home|back|lock|volumeUp|volumeDown|appSwitcher>');
    exit(opts.flag('help') ? 0 : 64);
  }

  final vm = VmClient();
  await vm.attach(Uri.parse(opts['vm-uri'] as String));
  final reader = SceneReader(InspectorClient(vm));
  final scene = await reader.readSummary();
  final resolver = CoordinateResolver(vm);

  // Build backend.
  final InteractionBackend backend;
  switch (opts['platform'] as String) {
    case 'android':
      backend = AdbBackend(
        deviceSerial: opts['device'] as String,
        adbPath: opts['adb-path'] as String,
      );
    case 'ios':
      // Look up the device's logical viewport from any resolved node.
      // Picking the root: its bounds are the full view.
      final probeId = scene.root.children.isNotEmpty
          ? _firstHittableId(scene.root) ?? scene.root.glintId!
          : scene.root.glintId!;
      final probe = await resolver.resolve(scene, probeId);
      backend = IosSimBackend(
        udid: opts['device'] as String,
        deviceLogicalWidth: probe.logicalViewSize.w,
        deviceLogicalHeight: probe.logicalViewSize.h,
        devicePixelRatio: probe.devicePixelRatio,
        binaryPath: opts['ios-bridge'] as String,
      );
    default:
      throw StateError('unreachable: ${opts['platform']}');
  }

  final interactor = Interactor(backend: backend, resolver: resolver)
    ..refuseNotHittable = opts.flag('refuse-not-hittable');

  // Parse the action command.
  final action = _parseAction(opts.rest);

  try {
    final result = await interactor.run(scene, action);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.toJson()));
    exit(result.ok ? 0 : 1);
  } finally {
    await scene.dispose();
    await vm.disconnect();
  }
}

Action _parseAction(List<String> rest) {
  switch (rest[0]) {
    case 'tap':
      _require(rest.length == 2, 'tap takes one <glintId>');
      return Tap(SymbolicTarget(rest[1]));
    case 'swipe':
      _require(rest.length == 3, 'swipe takes <fromGlintId> <toGlintId>');
      return Swipe(SymbolicTarget(rest[1]), SymbolicTarget(rest[2]));
    case 'press':
      _require(rest.length == 2, 'press takes one button name');
      final btn = HardwareButton.values.firstWhere(
        (b) => b.name == rest[1],
        orElse: () => throw ArgumentError('unknown button: ${rest[1]}'),
      );
      return PressHardwareButton(btn);
    default:
      throw ArgumentError('unknown command: ${rest[0]}');
  }
}

String? _firstHittableId(SceneNode n) {
  for (final c in n.walk().skip(1)) {
    if (c.glintId != null && c.glintId!.isNotEmpty) return c.glintId;
  }
  return null;
}

void _require(bool cond, String msg) {
  if (!cond) {
    stderr.writeln(msg);
    exit(64);
  }
}
