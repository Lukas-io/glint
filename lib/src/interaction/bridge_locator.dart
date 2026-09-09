import 'dart:io';

/// The glint-iossim bridge path relative to glint's package root.
const String kDefaultBridgePath =
    'native/ios_sim_bridge/.build/debug/glint-iossim';

/// Resolves the glint-iossim bridge: explicit arg, then the copy inside glint's
/// own package tree (the MCP server's CWD is the host app's dir, not glint's),
/// then the legacy CWD-relative default.
String resolveIosBridgePath(String? explicit) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return _bridgeUnderGlintRoot() ?? kDefaultBridgePath;
}

/// Walks up from the running script to find the bridge under glint's package.
String? _bridgeUnderGlintRoot() {
  Directory dir;
  try {
    dir = File(Platform.script.toFilePath()).parent;
  } catch (_) {
    return null;
  }
  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}/$kDefaultBridgePath');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
