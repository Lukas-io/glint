import 'dart:io';

import 'package:args/args.dart';

const String version = '0.0.1';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('version', negatable: false, help: 'Print version and exit.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (results.flag('help')) {
    stdout.writeln('glint — let an AI agent use your Flutter app.');
    stdout.writeln(parser.usage);
    return;
  }
  if (results.flag('version')) {
    stdout.writeln('glint $version');
    return;
  }

  // MCP server lands in Phase 4. Until then this binary is a placeholder;
  // the working surface is tool/smoke.dart.
  stderr.writeln(
    'glint $version — MCP server not implemented yet (Phase 4). '
    'Run the P0 smoke harness instead: dart run tool/smoke.dart --help',
  );
  exit(1);
}
