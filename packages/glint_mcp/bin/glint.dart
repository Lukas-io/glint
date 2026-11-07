// glint MCP server — speaks JSON-RPC over stdio.
// Logs must go to stderr; stdout is the wire protocol.
//
//   dart run bin/glint.dart [--version | --help]

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:glint_core/glint_core.dart';
import 'package:glint_mcp/glint.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('version', negatable: false, help: 'Print version and exit.')
    ..addFlag('prune-cache',
        negatable: false, help: 'Remove helper binaries of other glint versions and runner builds of gone Xcodes.')
    ..addFlag('dry-run', negatable: false, help: 'With --prune-cache: list what would be removed, remove nothing.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final ArgResults opts;
  try {
    opts = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (opts.flag('help')) {
    stdout
      ..writeln('glint — MCP server letting AI agents drive Flutter apps.')
      ..writeln(parser.usage);
    return;
  }
  if (opts.flag('version')) {
    stdout.writeln('glint $glintVersion');
    return;
  }

  if (opts.flag('prune-cache')) {
    final report = await pruneCaches(dryRun: opts.flag('dry-run'), force: true);
    for (final item in report.items) {
      stdout.writeln('${(item.bytes / 1048576).toStringAsFixed(2)} MB  ${item.path}  (${item.reason})');
    }
    stdout.writeln(report.summary);
    return;
  }

  final channel = stdioChannel(input: stdin, output: stdout);
  final server = GlintMcpServer.fromStreamChannel(channel);

  // Daily-gated, fire-and-forget. Runs the rollup ship for events
  // accumulated by the previous instance(s). Never throws.
  unawaited(server.session.usageReporter.maybeAutoShip());
  unawaited(refreshUpdateCheck());
  unawaited(_tidyUp());

  // Exit paths. `await server.done; return;` is NOT enough on its own:
  // with a session attached, the VM-service WebSocket (and any `flutter
  // run` child we spawned) keeps the Dart event loop alive after main
  // returns, orphaning the process when the MCP host dies or reconnects.
  // So on either trigger — channel closed (stdin EOF) or SIGTERM/SIGINT —
  // kill our children and exit(0) explicitly; lingering sockets don't
  // get a vote.
  var exiting = false;
  Future<void> shutdown(String reason) async {
    if (exiting) return;
    exiting = true;
    stderr.writeln('glint: $reason — shutting down.');
    Timer(const Duration(seconds: 12), () => exit(0));
    try {
      server.session.watches.close();
    } catch (_) {/* best effort */}
    try {
      server.session.explore.close();
    } catch (_) {/* best effort */}
    try {
      await server.session.killLaunchedApps();
      await ProcessRegistry.instance.stopAll();
    } catch (_) {/* best effort */}
    try {
      await server.session.usageReporter.shipOnExit().timeout(const Duration(seconds: 3));
    } catch (_) {/* best effort */}
    exit(0);
  }

  watchParentDeath(() => shutdown('the process that started glint exited'));

  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    try {
      signal.watch().listen((s) => shutdown('received $s'));
    } on UnsupportedError {
      // sigterm cannot be watched on Windows; stdin EOF still covers it.
    }
  }

  // Block until the client disconnects. dart_mcp closes `done` when the
  // underlying channel goes away or shutdown completes.
  await server.done;
  await shutdown('MCP host closed the stdio channel');
}

/// Startup housekeeping that must never delay the handshake: stop helpers a crashed glint left, and prune old caches.
Future<void> _tidyUp() async {
  try {
    final reaped = await ProcessRegistry.instance.reapStale();
    if (reaped.isNotEmpty) {
      stderr.writeln('glint: stopped ${reaped.length} helper(s) left by an earlier glint: ${reaped.join('; ')}');
    }
    final pruned = await pruneCaches();
    if (pruned.items.isNotEmpty) stderr.writeln('glint: ${pruned.summary}');
  } catch (_) {/* best effort */}
}
