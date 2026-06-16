// P1 verification gate. Runs against a fixture-app VM URI, expects the
// counter+flags-lab page. Asserts:
//   1. Scene reads have stable ids (twice in a row → identical).
//   2. Ids remain stable after a state change (counter increment).
//   3. The painted/hittable matrix matches expectation for the three
//      test buttons in _FlagsLab.
//
// Exit code 0 if all gates pass, 1 otherwise.
//
//   dart run tool/verify_p1.dart --vm-uri ws://...

import 'dart:io';

import 'package:args/args.dart';
import 'package:glint/glint.dart';

const _expectations = <String, ({bool painted, bool hittable})>{
  'elevated_button_in_flags_lab': (painted: true, hittable: true),
  'elevated_button_in_opacity': (painted: false, hittable: true),
  'elevated_button_in_absorb_pointer': (painted: true, hittable: false),
};

void pass(String msg) => stdout.writeln('  PASS  $msg');
void fail(String msg) => stdout.writeln('  FAIL  $msg');
void section(String msg) => stdout.writeln('\n== $msg ==');

Future<void> main(List<String> args) async {
  final parser = ArgParser()..addOption('vm-uri', mandatory: true);
  final opts = parser.parse(args);

  final vm = VmServiceRuntime();
  await vm.attach(Uri.parse(opts['vm-uri'] as String));
  final inspector = InspectorClient(vm);
  final reader = SceneReader(inspector, vm);
  final resolver = CoordinateResolver(vm);

  var failed = 0;
  try {
    section('Gate 1: stable ids across reads');
    final a = await reader.readSummary();
    final b = await reader.readSummary();
    final idsA = a.root.walk().map((n) => n.glintId).toList();
    final idsB = b.root.walk().map((n) => n.glintId).toList();
    if (_listEq(idsA, idsB)) {
      pass('two consecutive scene reads produced identical ids '
          '(${idsA.length} nodes)');
    } else {
      fail('ids differ across reads');
      failed++;
    }
    await b.dispose();

    section('Gate 2: ids stable after state change');
    // We use the fixture's helpers (glintLocateByRuntimeType +
    // glintSyntheticTap) only to drive the state — Module B itself stays
    // out of fixture cooperation.
    final fabLocate = await vm
        .evaluateString('glintLocateByRuntimeType("FloatingActionButton")');
    final coords = fabLocate!.split(',');
    final x = double.parse(coords[0]), y = double.parse(coords[1]);
    await vm.evaluate('glintSyntheticTap($x, $y)');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final c = await reader.readSummary();
    final idsC = c.root.walk().map((n) => n.glintId).toList();
    if (_listEq(idsA, idsC)) {
      pass('ids unchanged after a counter tap '
          '(textPreview changed but glintIds did not)');
    } else {
      fail('ids changed after state mutation');
      failed++;
    }
    await c.dispose();
    await a.dispose();

    section('Gate 3: painted/hittable matrix');
    final scene = await reader.readSummary();
    try {
      for (final entry in _expectations.entries) {
        final id = entry.key;
        final expected = entry.value;
        ResolvedCoord r;
        try {
          r = await resolver.resolve(scene, id);
        } on GeometryResolveError catch (e) {
          fail('$id: resolve failed: $e');
          failed++;
          continue;
        }
        final hit = r.hittable;
        final paint = r.painted;
        if (hit == expected.hittable && paint == expected.painted) {
          pass('$id  painted=$paint  hittable=$hit');
        } else {
          fail('$id  painted=$paint (expected ${expected.painted})  '
              'hittable=$hit (expected ${expected.hittable})');
          failed++;
        }
      }
    } finally {
      await scene.dispose();
    }
  } finally {
    await vm.disconnect();
  }

  stdout.writeln(failed == 0 ? '\nP1 VERIFY: GREEN' : '\nP1 VERIFY: RED ($failed failures)');
  exit(failed == 0 ? 0 : 1);
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
