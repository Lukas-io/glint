// glint MCP server — speaks JSON-RPC over stdio.
// Logs must go to stderr; stdout is the wire protocol.
//
//   dart run bin/glint.dart [--version | --help]

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

  // Block until the client disconnects. dart_mcp closes `done` when the
  // underlying channel goes away or shutdown completes.
  await server.done;
}
