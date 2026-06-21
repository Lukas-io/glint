/// Strips filesystem identity (username, project, dir layout) from arbitrary
/// text — Dart stack frames, action-log dumps — so it's safe to ship off the
/// user's machine (telemetry, GitHub issue bodies). Handles POSIX `$HOME` and
/// Windows `%USERPROFILE%` paths, preserves the project name as a
/// non-identifying `<project:…>` label, and leaves `package:` URIs alone.
/// Idempotent.
String redactPath(String input) {
  if (input.isEmpty) return input;
  var s = input;
  // Project-aware redaction FIRST — most specific match wins.
  s = s.replaceAllMapped(_posixStudioProjectsRegex, (m) {
    return '<project:${m.group(1)}>/';
  });
  s = s.replaceAllMapped(_windowsStudioProjectsRegex, (m) {
    return r'<project:' '${m.group(1)}' r'>\';
  });
  // Generic homedir fallback.
  s = s.replaceAll(_posixHomeRegex, '<home>/');
  s = s.replaceAll(_windowsHomeRegex, r'<home>\');
  return s;
}

/// Redacts every line of a Dart stack trace. Splits on `\n`, redacts each
/// line independently, keeps the first [maxFrames] frames.
List<String> redactStackHead(StackTrace stack, {int maxFrames = 8}) {
  final lines = stack.toString().split('\n');
  final head = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    head.add(redactPath(trimmed));
    if (head.length >= maxFrames) break;
  }
  return head;
}

/// `/Users/<name>/StudioProjects/<project>/` — captures the project name
/// so we can preserve it as a non-identifying label.
final RegExp _posixStudioProjectsRegex =
    RegExp(r'/Users/[^/]+/StudioProjects/([^/]+)/');

/// Generic POSIX homedir fallback.
final RegExp _posixHomeRegex = RegExp(r'/Users/[^/]+/');

/// `C:\Users\<name>\StudioProjects\<project>\` — Windows analog.
final RegExp _windowsStudioProjectsRegex =
    RegExp(r'C:\\Users\\[^\\]+\\StudioProjects\\([^\\]+)\\');

/// Generic Windows homedir fallback.
final RegExp _windowsHomeRegex = RegExp(r'C:\\Users\\[^\\]+\\');
