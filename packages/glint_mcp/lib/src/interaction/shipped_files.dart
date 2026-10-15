import 'dart:io';
import 'dart:isolate';

/// The path of [relative], a file or directory shipped with glint, or null: up from the running script (a checkout), then in the installed package (a pub.dev install).
String? shippedPath(String relative, {String? scriptPath}) {
  Directory? dir;
  try {
    dir = File(scriptPath ?? Platform.script.toFilePath()).parent;
  } catch (_) {
    dir = null;
  }
  for (var i = 0; dir != null && i < 6; i++) {
    final p = '${dir.path}/$relative';
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) return p;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final root = _installedPackageRoot();
  if (root == null) return null;
  final p = '$root/$relative';
  return FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound ? null : p;
}

/// glint_mcp's own directory from the package config; null in a compiled binary, which has none.
String? _installedPackageRoot() {
  try {
    final lib = Isolate.resolvePackageUriSync(Uri.parse('package:glint_mcp/'));
    if (lib == null) return null;
    final root = lib.resolve('..').toFilePath();
    return root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  } on Object {
    return null;
  }
}
