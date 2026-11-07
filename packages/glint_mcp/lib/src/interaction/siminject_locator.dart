import 'dart:io';

import '../media/host_tools.dart';
import 'bounded_process.dart';
import '../version.dart';
import 'bridge_locator.dart';
import 'shipped_files.dart';

/// Must equal the protocol the injected dylib reports from native/ios_sim_inject.
const int siminjectProtocol = 1;

/// The built sim-injection dylib relative to glint's package root.
const String kSimInjectBuildPath = 'native/ios_sim_inject/.build/glint-siminject.dylib';

/// The sim-injection sources relative to glint's package root.
const String kSimInjectSourceDir = 'native/ios_sim_inject';

/// Env var naming a sim-injection dylib to use instead of the one glint finds.
const String simInjectPathEnv = 'GLINT_SIMINJECT';

class SimInjectError implements Exception {
  SimInjectError(this.message, this.detail, this.nextSteps);

  final String message;
  final String detail;
  final List<String> nextSteps;

  @override
  String toString() => '$message: $detail';
}

/// The downloaded or compiled dylib for this glint version, under `~/.glint/bin`.
String cachedSimInjectPath({Map<String, String>? env}) {
  final home = (env ?? Platform.environment)['HOME'] ?? '.';
  return '$home/.glint/bin/glint-siminject-$glintVersion.dylib';
}

/// Finds the dylib: explicit arg, then [simInjectPathEnv], then a build inside glint's package, then the cache; [BridgeSource.missing] points at the cache path.
BridgeLocation locateSimInject(String? explicit, {Map<String, String>? env, String? scriptPath}) {
  if (explicit != null && explicit.isNotEmpty) {
    return BridgeLocation(explicit, BridgeSource.argument);
  }
  final fromEnv = (env ?? Platform.environment)[simInjectPathEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return BridgeLocation(fromEnv, BridgeSource.env);
  }
  final built = shippedPath(kSimInjectBuildPath, scriptPath: scriptPath);
  if (built != null && File(built).existsSync()) return BridgeLocation(built, BridgeSource.build);
  final cached = cachedSimInjectPath(env: env);
  return BridgeLocation(cached, File(cached).existsSync() ? BridgeSource.cache : BridgeSource.missing);
}

/// Compiles the shipped sources into the cache path with Xcode's clang and returns it.
Future<String> buildSimInjectFromSource({PhaseReporter? phases, Map<String, String>? env}) async {
  final dir = shippedPath(kSimInjectSourceDir);
  if (dir == null || !File('$dir/build.sh').existsSync()) {
    throw SimInjectError(
        'the sim-injection sources are not part of this glint install', 'looked for $kSimInjectSourceDir', [
      'Reinstall glint, or set $simInjectPathEnv to a prebuilt glint-siminject.dylib.',
    ]);
  }
  final dest = cachedSimInjectPath(env: env);
  Future<ProcessResult> compile() async {
    try {
      final tool = await runBounded('xcrun', ['--sdk', 'iphonesimulator', '--find', 'clang'],
          timeout: const Duration(seconds: 30), phase: 'finding the iOS simulator compiler');
      if (tool.exitCode != 0) {
        throw SimInjectError('the Xcode iOS simulator toolchain is missing', '${tool.stderr}'.trim(), [
          'Install Xcode and run: xcode-select --install',
          'Or set $simInjectPathEnv to a prebuilt glint-siminject.dylib.',
        ]);
      }
    } on ProcessException catch (e) {
      throw SimInjectError('xcrun is not available', e.message, [
        'Install the Xcode command line tools: xcode-select --install',
        'Or set $simInjectPathEnv to a prebuilt glint-siminject.dylib.',
      ]);
    }
    await Directory(File(dest).parent.path).create(recursive: true);
    return runBounded('sh', ['$dir/build.sh', dest],
        timeout: const Duration(minutes: 5), phase: 'compiling the glint sim-injection library');
  }

  final phase = 'compiling the glint sim-injection library for glint $glintVersion';
  final result = await (phases == null ? compile() : phases.during(phase, compile));
  if (result.exitCode != 0 || !File(dest).existsSync()) {
    final tail = '${result.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    throw SimInjectError('could not compile the sim-injection library with the Xcode toolchain',
        tail.skip(tail.length > 8 ? tail.length - 8 : 0).join(' | '), [
      'Check that Xcode is installed with the iOS simulator SDK.',
      'Or set $simInjectPathEnv to a prebuilt glint-siminject.dylib.',
    ]);
  }
  return dest;
}
