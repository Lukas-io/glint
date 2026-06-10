// P0 smoke harness.
//
// Proves the foundational loop on one platform per invocation:
//   launch (or attach) -> read render/widget tree -> locate target ->
//   tap -> verify state changed.
//
// Usage:
//   dart run tool/smoke.dart --device <flutter-device-id> --tap-mode adb
//   dart run tool/smoke.dart --device <flutter-device-id> --tap-mode synthetic
//   dart run tool/smoke.dart --vm-uri ws://127.0.0.1:PORT/TOKEN/ws --tap-mode synthetic
//
// --tap-mode adb       : OS-level tap via `adb shell input tap` (Android).
// --tap-mode synthetic : in-app pointer dispatch via VM-service evaluate
//                        (iOS interim path until the P2 Swift bridge).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _fixtureDir = 'fixtures/counter_app';

void ok(String msg) => stdout.writeln('  PASS  $msg');
void fail(String msg) => stdout.writeln('  FAIL  $msg');
void info(String msg) => stdout.writeln('        $msg');
void section(String msg) => stdout.writeln('\n== $msg ==');

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('device', help: 'Flutter device id to launch the fixture on.')
    ..addOption('vm-uri', help: 'Attach to an already-running app instead.')
    ..addOption('tap-mode',
        allowed: ['adb', 'synthetic'], help: 'How to deliver the tap.')
    ..addOption('adb-serial', help: 'adb -s serial (when multiple devices).')
    ..addOption('android-package',
        defaultsTo: 'com.example.counter_fixture',
        help: 'Android package to foreground before adb taps.')
    ..addFlag('help', abbr: 'h', negatable: false);
  final opts = parser.parse(args);

  if (opts.flag('help') ||
      (opts['device'] == null && opts['vm-uri'] == null) ||
      opts['tap-mode'] == null) {
    stdout.writeln('P0 smoke harness.\n${parser.usage}');
    exit(64);
  }

  final tapMode = opts['tap-mode'] as String;
  FlutterRunSession? session;
  Uri vmUri;

  if (opts['vm-uri'] != null) {
    vmUri = Uri.parse(opts['vm-uri'] as String);
  } else {
    section('Launch fixture (${opts['device']})');
    session = await FlutterRunSession.start(
      device: opts['device'] as String,
      cwd: _fixtureDir,
    );
    vmUri = session.vmServiceWsUri;
    ok('flutter run started, VM service at $vmUri');
  }

  var exitCode = 1;
  try {
    exitCode = await runSmoke(
      vmUri,
      tapMode,
      opts['adb-serial'] as String?,
      opts['android-package'] as String,
    );
  } finally {
    await session?.stop();
  }
  exit(exitCode);
}

Future<int> runSmoke(
  Uri vmUri,
  String tapMode,
  String? adbSerial,
  String androidPackage,
) async {
  section('Attach');
  final service = await vmServiceConnectUri(_toWs(vmUri));
  try {
    await service.getVersion().timeout(const Duration(seconds: 5));
  } on Object {
    fail('VM service accepted connection but did not answer getVersion in 5s');
    return 1;
  }
  ok('connected to VM service');

  // For adb taps the target app MUST be in the foreground — Android delivers
  // a zero-size surface to background apps, which degrades layout to (0,0)
  // and makes lazy coordinate resolution return garbage. Do this before any
  // perception read, not just before the tap. (Module A in P2 takes over
  // this responsibility.)
  if (tapMode == 'adb') {
    final ok = await _ensureAndroidForeground(adbSerial, androidPackage);
    if (!ok) return 1;
  }

  // Find the Flutter isolate.
  final vm = await service.getVM();
  Isolate? flutterIsolate;
  for (final ref in vm.isolates ?? const <IsolateRef>[]) {
    final iso = await service.getIsolate(ref.id!);
    if ((iso.extensionRPCs ?? const [])
        .any((r) => r.startsWith('ext.flutter.'))) {
      flutterIsolate = iso;
      break;
    }
  }
  if (flutterIsolate == null) {
    fail('no isolate exposes ext.flutter.* extensions');
    return 1;
  }
  final isolateId = flutterIsolate.id!;
  ok('Flutter isolate: ${flutterIsolate.name} ($isolateId)');

  section('Access-path pin (evidence for source-of-truth §10)');
  final rpcs = (flutterIsolate.extensionRPCs ?? const <String>[]).toList()
    ..sort();
  final inspector =
      rpcs.where((r) => r.startsWith('ext.flutter.inspector.')).toList();
  info('ext.flutter.* count: '
      '${rpcs.where((r) => r.startsWith('ext.flutter.')).length}');
  info('ext.flutter.inspector.* count: ${inspector.length}');
  for (final candidate in [
    'ext.flutter.inspector.getRootWidgetTree',
    'ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews',
    'ext.flutter.inspector.getRootWidgetSummaryTree',
    'ext.flutter.inspector.getLayoutExplorerNode',
    'ext.flutter.inspector.getDetailsSubtree',
    'ext.flutter.inspector.screenshot',
    'ext.flutter.debugDumpRenderTree',
    'ext.flutter.debugDumpApp',
    'ext.flutter.debugDumpLayerTree',
  ]) {
    info('${rpcs.contains(candidate) ? '[x]' : '[ ]'} $candidate');
  }

  section('Dump 5 render nodes');
  try {
    final dump = await service.callServiceExtension(
      'ext.flutter.debugDumpRenderTree',
      isolateId: isolateId,
    );
    final text = (dump.json?['data'] ?? dump.json?['result'] ?? '') as String;
    final lines = const LineSplitter().convert(text);
    for (final line in lines.take(5)) {
      info(line.length > 110 ? '${line.substring(0, 110)}…' : line);
    }
    ok('render tree dump returned ${lines.length} lines');
  } on Object catch (e) {
    fail('debugDumpRenderTree: $e');
    return 1;
  }

  section('Widget tree (JSON, with previews)');
  Map<String, Object?>? root;
  for (final (method, extraArgs) in [
    (
      'ext.flutter.inspector.getRootWidgetTree',
      {
        'isSummaryTree': 'true',
        'withPreviews': 'true',
        'fullDetails': 'false'
      }
    ),
    ('ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews', <String, String>{}),
    ('ext.flutter.inspector.getRootWidgetSummaryTree', <String, String>{}),
  ]) {
    if (!rpcs.contains(method)) continue;
    try {
      final resp = await service.callServiceExtension(
        method,
        isolateId: isolateId,
        args: {'groupName': 'glint-smoke', ...extraArgs},
      );
      root = (resp.json?['result'] as Map?)?.cast<String, Object?>();
      if (root != null) {
        ok('widget tree via $method');
        break;
      }
    } on Object catch (e) {
      info('$method failed: $e');
    }
  }
  if (root == null) {
    fail('no widget-tree inspector method worked');
    return 1;
  }

  int? readCounter() {
    int? found;
    void visit(Map<String, Object?> node) {
      if (found != null) return;
      final preview = node['textPreview'];
      if (preview is String) {
        final n = int.tryParse(preview.trim());
        if (n != null) found = n;
      }
      for (final child in (node['children'] as List? ?? const [])) {
        visit((child as Map).cast<String, Object?>());
      }
    }

    visit(root!);
    return found;
  }

  final before = readCounter();
  if (before == null) {
    fail('could not find numeric Text preview in widget tree');
    return 1;
  }
  ok('counter reads $before before tap');

  section('Locate FAB via evaluate (lazy coordinate resolution)');
  final rootLibId = flutterIsolate.rootLib?.id;
  if (rootLibId == null) {
    fail('isolate has no rootLib');
    return 1;
  }
  // VM-service evaluate() compiles its input as an EXPRESSION — it accepts
  // arrow-body lambdas but not statement-block function bodies. Walking the
  // render tree to find an element by type needs statements, so for P0 the
  // fixture exposes `glintLocateByRuntimeType` (see main.dart). Module B
  // (P1) replaces this with server-side inspector-JSON walking — no
  // cooperation from the target app required.
  const locateExpr = 'glintLocateByRuntimeType("FloatingActionButton")';
  final String coords;
  try {
    final result = await service.evaluate(isolateId, rootLibId, locateExpr);
    if (result is! InstanceRef || result.valueAsString == null) {
      fail('evaluate returned ${result.runtimeType}: ${result.toJson()}');
      return 1;
    }
    coords = result.valueAsString!;
  } on Object catch (e) {
    fail('evaluate(locate FAB): $e');
    return 1;
  }
  final parts = coords.split(',');
  if (parts.length != 3) {
    fail('unexpected locate result: "$coords"');
    return 1;
  }
  final x = double.parse(parts[0]);
  final y = double.parse(parts[1]);
  final dpr = double.parse(parts[2]);
  ok('FAB center: logical ($x, $y), devicePixelRatio $dpr');

  section('Tap ($tapMode)');
  switch (tapMode) {
    case 'adb':
      final px = (x * dpr).round();
      final py = (y * dpr).round();
      final result = await Process.run('adb', [
        if (adbSerial != null) ...['-s', adbSerial],
        'shell',
        'input',
        'tap',
        '$px',
        '$py',
      ]);
      if (result.exitCode != 0) {
        fail('adb input tap: ${result.stderr}');
        return 1;
      }
      ok('OS-level tap at physical ($px, $py) via adb');
    case 'synthetic':
      final tapExpr = 'glintSyntheticTap($x, $y)';
      try {
        final result = await service.evaluate(isolateId, rootLibId, tapExpr);
        if (result is! InstanceRef || result.valueAsString != 'ok') {
          fail('synthetic tap evaluate: '
              '${result is InstanceRef ? result.valueAsString : result.toJson()}');
          return 1;
        }
      } on Object catch (e) {
        fail('evaluate(synthetic tap): $e');
        return 1;
      }
      ok('in-app pointer dispatch at logical ($x, $y) '
          '(interim until P2 Swift bridge)');
  }

  section('Verify');
  // Crude settle for P0 — real settle detection is P6.
  await Future<void>.delayed(const Duration(milliseconds: 800));
  // Re-read the widget tree.
  final resp = await service.callServiceExtension(
    rpcs.contains('ext.flutter.inspector.getRootWidgetTree')
        ? 'ext.flutter.inspector.getRootWidgetTree'
        : 'ext.flutter.inspector.getRootWidgetSummaryTreeWithPreviews',
    isolateId: isolateId,
    args: {
      'groupName': 'glint-smoke-2',
      if (rpcs.contains('ext.flutter.inspector.getRootWidgetTree')) ...{
        'isSummaryTree': 'true',
        'withPreviews': 'true',
        'fullDetails': 'false',
      },
    },
  );
  root = (resp.json?['result'] as Map?)?.cast<String, Object?>();
  final after = readCounter();
  if (after == before + 1) {
    ok('counter incremented: $before -> $after');
    stdout.writeln('\nSMOKE: GREEN');
    await service.dispose();
    return 0;
  }
  fail('counter did not increment: $before -> $after');
  stdout.writeln('\nSMOKE: RED');
  await service.dispose();
  return 1;
}

Future<bool> _ensureAndroidForeground(
  String? adbSerial,
  String androidPackage,
) async {
  final focused = await Process.run('adb', [
    if (adbSerial != null) ...['-s', adbSerial],
    'shell',
    'dumpsys',
    'window',
  ]);
  final focusLine = const LineSplitter()
      .convert(focused.stdout as String)
      .firstWhere((l) => l.contains('mCurrentFocus='), orElse: () => '');
  if (focusLine.contains(androidPackage)) {
    info('foreground is $androidPackage');
    return true;
  }
  info('foreground is not $androidPackage — bringing it up');
  final start = await Process.run('adb', [
    if (adbSerial != null) ...['-s', adbSerial],
    'shell',
    'monkey',
    '-p',
    androidPackage,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  ]);
  if (start.exitCode != 0) {
    fail('failed to foreground $androidPackage: ${start.stderr}');
    return false;
  }
  // Wait for the view to actually be sized — a fresh foreground takes a
  // few frames before layout completes. Poll dumpsys until the focused
  // window is ours, with a ceiling.
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final check = await Process.run('adb', [
      if (adbSerial != null) ...['-s', adbSerial],
      'shell',
      'dumpsys',
      'window',
    ]);
    final line = const LineSplitter()
        .convert(check.stdout as String)
        .firstWhere((l) => l.contains('mCurrentFocus='), orElse: () => '');
    if (line.contains(androidPackage)) {
      // Extra settle for first layout pass.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      ok('foreground is now $androidPackage');
      return true;
    }
  }
  fail('foregrounding $androidPackage did not take within 8s');
  return false;
}

String _toWs(Uri uri) {
  if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri.toString();
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isEmpty || segments.last != 'ws') segments.add('ws');
  return Uri(
          scheme: scheme,
          host: uri.host,
          port: uri.port,
          pathSegments: segments)
      .toString();
}

/// Spawns `flutter run --machine`, waits for the VM service URI, and can
/// stop the app cleanly. Seed of the P-launch session manager.
class FlutterRunSession {
  FlutterRunSession._(this._process, this.vmServiceWsUri, this._appId);

  final Process _process;
  final Uri vmServiceWsUri;
  final String? _appId;
  int _nextId = 1;

  static Future<FlutterRunSession> start({
    required String device,
    required String cwd,
  }) async {
    final process = await Process.start(
      'flutter',
      ['run', '--machine', '-d', device],
      workingDirectory: cwd,
    );
    final completer = Completer<(Uri, String?)>();
    String? appId;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on Object {
        return; // non-JSON noise from the tool
      }
      if (decoded is! List || decoded.isEmpty) return;
      final event = (decoded.first as Map).cast<String, Object?>();
      final params = (event['params'] as Map?)?.cast<String, Object?>();
      switch (event['event']) {
        case 'app.start':
          appId = params?['appId'] as String?;
        case 'app.debugPort':
          final wsUri = params?['wsUri'] as String?;
          if (wsUri != null && !completer.isCompleted) {
            completer.complete((Uri.parse(wsUri), appId));
          }
      }
    });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[flutter run] $line'));

    final (uri, id) = await completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        process.kill();
        throw TimeoutException('flutter run produced no app.debugPort in 5m');
      },
    );
    return FlutterRunSession._(process, uri, id);
  }

  Future<void> stop() async {
    if (_appId != null) {
      _process.stdin.writeln(jsonEncode([
        {
          'id': _nextId++,
          'method': 'app.stop',
          'params': {'appId': _appId},
        }
      ]));
      await _process.stdin.flush();
      // Give it a moment to shut down gracefully, then make sure.
      await _process.exitCode
          .timeout(const Duration(seconds: 10))
          .catchError((Object? _) {
        _process.kill();
        return 0;
      });
    } else {
      _process.kill();
    }
  }
}
