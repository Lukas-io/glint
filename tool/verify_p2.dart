// P2 verification gate. Runs against a fixture-app VM URI plus a backend.
// Exercises the action set through the Interactor + symbolic ids:
//   1. Tap on a known glintId (`floating_action_button`) increments the
//      counter visible in the scene.
//   2. Tap on a non-hittable target (`elevated_button_in_absorb_pointer`)
//      returns a result with `ok:true` but `hittable:false` plus a
//      warning. With --refuse-not-hittable, returns `ok:false` and
//      errorClass:"NotHittable" instead.
//   3. Tap on an unknown glintId returns `ok:false` and
//      errorClass:"UnresolvedTarget".
//
// Exits 0 if every gate passes, 1 otherwise.
//
//   dart run tool/verify_p2.dart \
//     --vm-uri ws://... \
//     --platform ios|android \
//     --device <udid|serial>

import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

void pass(String msg) => stdout.writeln('  PASS  $msg');
void fail(String msg) => stdout.writeln('  FAIL  $msg');
void info(String msg) => stdout.writeln('        $msg');
void section(String msg) => stdout.writeln('\n== $msg ==');

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('vm-uri', mandatory: true)
    ..addOption('platform', allowed: ['ios', 'android'], mandatory: true)
    ..addOption('device', mandatory: true)
    ..addOption('ios-bridge',
        defaultsTo: 'native/ios_sim_bridge/.build/debug/glint-iossim')
    ..addOption('adb-path', defaultsTo: 'adb');
  final opts = parser.parse(argv);

  final vm = VmClient();
  await vm.attach(Uri.parse(opts['vm-uri'] as String));
  final reader = SceneReader(InspectorClient(vm));
  final resolver = CoordinateResolver(vm);

  // Probe the device's logical viewport once for the iOS backend.
  final probeScene = await reader.readSummary();
  final probe = await resolver.resolve(probeScene, 'floating_action_button');
  await probeScene.dispose();

  final InteractionBackend backend = switch (opts['platform'] as String) {
    'android' => AdbBackend(
        deviceSerial: opts['device'] as String,
        adbPath: opts['adb-path'] as String,
      ),
    'ios' => IosSimBackend(
        udid: opts['device'] as String,
        deviceLogicalWidth: probe.logicalViewSize.w,
        deviceLogicalHeight: probe.logicalViewSize.h,
        devicePixelRatio: probe.devicePixelRatio,
        binaryPath: opts['ios-bridge'] as String,
      ),
    _ => throw StateError('unreachable'),
  };

  var failed = 0;
  try {
    // ── Gate 1: tap a real, hittable target.
    section('Gate 1: tap on floating_action_button increments the counter');
    final scene1 = await reader.readSummary();
    final beforeText = _counterTextPreview(scene1);
    info('counter before: "$beforeText"');
    final interactor = Interactor(backend: backend, resolver: resolver);
    final r1 = await interactor.run(scene1, const Tap(SymbolicTarget('floating_action_button')));
    info('result: ${r1.summary}');
    await scene1.dispose();
    if (!r1.ok) {
      fail('action result was not ok: ${r1.error}');
      failed++;
    } else {
      // Re-read to see whether the counter advanced.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final scene1b = await reader.readSummary();
      final afterText = _counterTextPreview(scene1b);
      info('counter after:  "$afterText"');
      await scene1b.dispose();
      final before = int.tryParse(beforeText ?? '');
      final after = int.tryParse(afterText ?? '');
      if (before != null && after != null && after == before + 1) {
        pass('counter $before -> $after');
      } else {
        fail('counter did not increment: "$beforeText" -> "$afterText"');
        failed++;
      }
    }

    // ── Gate 2: tap on a target that is painted but NOT hittable.
    section('Gate 2: tap on elevated_button_in_absorb_pointer warns about hittable');
    final scene2 = await reader.readSummary();
    final r2 = await interactor.run(
      scene2,
      const Tap(SymbolicTarget('elevated_button_in_absorb_pointer')),
    );
    info('result: ${r2.summary}  warnings=${r2.warnings.length}');
    await scene2.dispose();
    if (r2.ok &&
        r2.hittable == false &&
        r2.warnings.any((w) => w.contains('not hittable'))) {
      pass('result is ok=true, hittable=false, with the expected warning '
          '(default permissive mode)');
    } else {
      fail('expected ok=true with hittable=false warning; got '
          'ok=${r2.ok} hittable=${r2.hittable} warnings=${r2.warnings}');
      failed++;
    }

    // ── Gate 3: refuse-not-hittable changes the outcome of gate 2.
    section('Gate 3: --refuse-not-hittable on the same tap returns NotHittable error');
    final scene3 = await reader.readSummary();
    final strict = Interactor(backend: backend, resolver: resolver)
      ..refuseNotHittable = true;
    final r3 = await strict.run(
      scene3,
      const Tap(SymbolicTarget('elevated_button_in_absorb_pointer')),
    );
    info('result: ok=${r3.ok} errorClass=${r3.errorClass}');
    await scene3.dispose();
    if (!r3.ok && r3.errorClass == 'NotHittable') {
      pass('refused with errorClass=NotHittable');
    } else {
      fail('expected ok=false errorClass=NotHittable; got ok=${r3.ok} '
          'errorClass=${r3.errorClass}');
      failed++;
    }

    // ── Gate 4: unknown glintId.
    section('Gate 4: tap on an unknown glintId returns UnresolvedTarget');
    final scene4 = await reader.readSummary();
    final r4 = await interactor.run(
      scene4,
      const Tap(SymbolicTarget('definitely_not_a_real_id_42')),
    );
    info('result: ok=${r4.ok} errorClass=${r4.errorClass}');
    await scene4.dispose();
    if (!r4.ok && r4.errorClass == 'UnresolvedTarget') {
      pass('refused with errorClass=UnresolvedTarget');
    } else {
      fail('expected ok=false errorClass=UnresolvedTarget; got ok=${r4.ok} '
          'errorClass=${r4.errorClass}');
      failed++;
    }
  } finally {
    await vm.disconnect();
  }

  stdout.writeln(failed == 0
      ? '\nP2 VERIFY: GREEN'
      : '\nP2 VERIFY: RED ($failed failures)');
  exit(failed == 0 ? 0 : 1);
}

String? _counterTextPreview(Scene scene) {
  // The counter is the second `Text` in the Column under SingleChildScrollView.
  for (final n in scene.root.walk()) {
    final p = n.textPreview;
    if (p != null && int.tryParse(p.trim()) != null) return p.trim();
  }
  return null;
}
