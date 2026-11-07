import 'dart:io';

import '../media/host_tools.dart';
import '../version.dart';
import 'bridge_download.dart';
import 'bridge_locator.dart';
import 'siminject_locator.dart';

/// The release asset name of the universal sim-injection dylib.
const String simInjectAssetName = 'glint-siminject.dylib';

/// Downloads the release dylib to [dest] and checks it against the published sha256.
Future<void> downloadSimInject(String dest, {BytesFetcher? fetch}) =>
    downloadReleaseAsset(simInjectAssetName, dest, fetch: fetch);

/// Resolves the dylib: explicit or env, a local build, the cache, a download, then a compile from source; throws [SimInjectError] when none works.
Future<String> ensureSimInject({
  String? explicit,
  PhaseReporter? phases,
  Map<String, String>? env,
  BytesFetcher? fetch,
}) async {
  final environment = env ?? Platform.environment;
  final location = locateSimInject(explicit, env: environment);
  if (location.source == BridgeSource.argument || location.source == BridgeSource.env) {
    if (File(location.path).existsSync()) return location.path;
    throw SimInjectError('no sim-injection dylib at ${location.path}',
        'it was named by ${location.source == BridgeSource.env ? simInjectPathEnv : 'the explicit path'}', [
      'Point it at a built glint-siminject.dylib, or unset it so glint downloads or compiles one.',
    ]);
  }
  if (location.found) return location.path;
  final dest = location.path;
  String? downloadError;
  if (environment[noBridgeDownloadEnv] == 'true') {
    downloadError = '$noBridgeDownloadEnv is set';
  } else {
    Future<void> download() => downloadSimInject(dest, fetch: fetch);
    final phase = 'downloading the glint sim-injection library for glint $glintVersion';
    try {
      await (phases == null ? download() : phases.during(phase, download));
      return dest;
    } on BridgeDownloadError catch (e) {
      downloadError = e.message;
    } on FileSystemException catch (e) {
      downloadError = 'could not save it to $dest: ${e.message}';
    }
  }
  try {
    return await buildSimInjectFromSource(phases: phases, env: environment);
  } on SimInjectError catch (e) {
    throw SimInjectError(e.message, '${e.detail} (download: $downloadError)', e.nextSteps);
  }
}
