import 'dart:io';

import '../version.dart';

/// The glint-iossim bridge path relative to glint's package root.
const String kDefaultBridgePath =
    'native/ios_sim_bridge/.build/debug/glint-iossim';

/// The release build of the bridge, relative to glint's package root.
const String kReleaseBridgePath =
    'native/ios_sim_bridge/.build/release/glint-iossim';

/// Env var naming a bridge binary to use instead of the one glint finds.
const String bridgePathEnv = 'GLINT_IOS_BRIDGE';

/// Where each bridge came from, in lookup order.
enum BridgeSource { argument, env, build, cache, missing }

class BridgeLocation {
  const BridgeLocation(this.path, this.source);

  final String path;
  final BridgeSource source;

  bool get found => source != BridgeSource.missing;
}

/// The downloaded bridge for this glint version, under `~/.glint/bin`.
String cachedBridgePath({Map<String, String>? env}) {
  final home = (env ?? Platform.environment)['HOME'] ?? '.';
  return '$home/.glint/bin/glint-iossim-$glintVersion';
}

/// Finds the bridge: explicit arg, then [bridgePathEnv], then a build inside glint's package (newest of release and debug), then the download cache; [BridgeSource.missing] points at the cache path.
BridgeLocation locateIosBridge(String? explicit,
    {Map<String, String>? env, String? scriptPath}) {
  if (explicit != null && explicit.isNotEmpty) {
    return BridgeLocation(explicit, BridgeSource.argument);
  }
  final fromEnv = (env ?? Platform.environment)[bridgePathEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return BridgeLocation(fromEnv, BridgeSource.env);
  }
  final built = _bridgeUnderGlintRoot(scriptPath);
  if (built != null) return BridgeLocation(built, BridgeSource.build);
  final cached = cachedBridgePath(env: env);
  return BridgeLocation(
      cached, File(cached).existsSync() ? BridgeSource.cache : BridgeSource.missing);
}

/// The bridge path [locateIosBridge] picks.
String resolveIosBridgePath(String? explicit) => locateIosBridge(explicit).path;

/// Walks up from the running script to glint's package and returns its newest bridge build.
String? _bridgeUnderGlintRoot(String? scriptPath) {
  Directory dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    return null;
  }
  for (var i = 0; i < 6; i++) {
    final builds = [
      for (final rel in [kReleaseBridgePath, kDefaultBridgePath])
        if (File('${dir.path}/$rel').existsSync()) File('${dir.path}/$rel'),
    ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (builds.isNotEmpty) return builds.first.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
