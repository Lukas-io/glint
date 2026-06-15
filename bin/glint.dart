// glint MCP server — speaks JSON-RPC over stdio.
// Logs must go to stderr; stdout is the wire protocol.
//
//   dart run bin/glint.dart [--version | --help]
//   glint install   # AOT-compile for sub-100ms startup
//   glint update    # re-fetch from git + re-AOT if previously installed

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:glint/glint.dart';
import 'package:glint/src/install/install.dart';
import 'package:glint/src/install/update.dart';
import 'package:glint/src/update/update_check.dart';

Future<void> main(List<String> args) async {
  // Top-level zone guard. Anything that escapes the per-call try/catches
  // inside the server / runtime / interactor lands here — we log it to
  // stderr (so the MCP host sees a closed channel, not a raw Dart trace)
  // and fire CrashReporter.maybeReport (default-on with opt-out via
  // GLINT_NO_TELEMETRY=true). See docs/CRASH_REPORTING.md.
  await runZonedGuarded(() => _runMain(args), (error, stack) {
    stderr.writeln(
      'glint: UNCAUGHT ERROR ($error). The MCP host will see the stdio '
      'channel close — restart your MCP host to recover. Please report '
      'at https://github.com/Lukas-io/glint/issues with the trace below.\n'
      '$stack',
    );
    unawaited(CrashReporter.maybeReport(error: error, stack: stack));
    exitCode = 70;
  });
}

Future<void> _runMain(List<String> args) async {
  // Subcommands short-circuit ArgParser. Keep this dispatch FIRST so a
  // typo on the main flags doesn't pre-empt `install` / `update`.
  if (args.isNotEmpty) {
    switch (args.first) {
      case 'install':
        return runInstall(args.skip(1).toList());
      case 'update':
        return runUpdate(args.skip(1).toList());
    }
  }

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
      ..writeln('')
      ..writeln('Subcommands:')
      ..writeln('  install   AOT-compile this install (sub-100ms startup).')
      ..writeln('  update    Re-fetch from git and re-compile if installed.')
      ..writeln('')
      ..writeln(parser.usage);
    return;
  }
  if (opts.flag('version')) {
    stdout.writeln('glint $packageVersion');
    return;
  }

  // JIT-mode startup nudge. `pub global activate -s git` ships a snapshot
  // wrapper that recompiles on every spawn (~1–2s cold), which the MCP
  // host can race and mark the server "Failed to connect" on first attach.
  // `dart.vm.product` is the canonical AOT-vs-JIT check.
  final env = Platform.environment;
  if (!isAotBuild && env['GLINT_NO_JIT_NUDGE']?.toLowerCase() != 'true') {
    stderr.writeln(
      'glint: running in JIT mode — slow cold-start may cause MCP host '
      'handshake timeouts on first attach. Run `glint install` once for '
      'sub-100ms native startup. (Silence with GLINT_NO_JIT_NUDGE=true.)',
    );
  }

  final channel = stdioChannel(input: stdin, output: stdout);
  final server = GlintMcpServer.fromStreamChannel(channel);

  // Daily-gated, fire-and-forget. Ships the rollup of events accumulated
  // by previous instance(s). Never throws.
  unawaited(server.session.usageReporter.maybeAutoShip());

  // Daily-gated, fire-and-forget. Probes upstream pubspec for a newer
  // version; nudges to stderr + writes status JSON for the agent. Opt-out
  // via GLINT_NO_UPDATE_CHECK=true.
  unawaited(UpdateCheck.maybeCheck(
    currentVersion: packageVersion,
    dataDir: resolveDataDir(),
  ));

  // Block until the client disconnects.
  await server.done;
}
