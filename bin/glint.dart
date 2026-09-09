// glint MCP server — speaks JSON-RPC over stdio.
// Logs must go to stderr; stdout is the wire protocol.
//
//   dart run bin/glint.dart [--version | --help]

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:glint/glint.dart';

const String version = '0.0.1';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('version', negatable: false, help: 'Print version and exit.')
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
    stdout.writeln('glint $version');
    return;
  }

  final channel = stdioChannel(input: stdin, output: stdout);
  final server = GlintMcpServer.fromStreamChannel(channel);

  // Daily-gated, fire-and-forget. Runs the rollup ship for events
  // accumulated by the previous instance(s). Never throws.
  unawaited(server.session.usageReporter.maybeAutoShip());

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
    try {
      server.session.killLaunchedApps();
    } catch (_) {/* best effort */}
    await server.session.usageReporter.shipOnExit();
    exit(0);
  }

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
