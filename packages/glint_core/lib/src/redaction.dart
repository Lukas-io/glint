import 'dart:io';

/// Strips filesystem identity (username, project name, directory layout) from text that leaves the machine; `<home>/…/lib/x.dart` becomes `<project>/lib/x.dart`, `package:` URIs are untouched, and it is idempotent.
String redactPath(String input, {String? home}) {
  if (input.isEmpty) return input;
  var s = input;
  final h = home ?? _homeDir();
  if (h != null && h.length > 1) {
    s = s.replaceAll('$h${Platform.pathSeparator}', '<home>${Platform.pathSeparator}');
    s = s.replaceAll('$h/', '<home>/');
  }
  s = s.replaceAll(_posixHomeRegex, '<home>/');
  s = s.replaceAll(_windowsHomeRegex, r'<home>\');
  s = s.replaceAllMapped(_posixProjectRegex, (m) => '<project>/${m[1]}/');
  s = s.replaceAllMapped(_windowsProjectRegex, (m) => '<project>\\${m[1]}\\');
  return s;
}

/// Redacts every line of a Dart stack trace, keeping the first [maxFrames] frames.
List<String> redactStackHead(StackTrace stack, {int maxFrames = 8}) {
  final head = <String>[];
  for (final line in stack.toString().split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    head.add(redactPath(trimmed));
    if (head.length >= maxFrames) break;
  }
  return head;
}

/// Masks bearer tokens, JWTs, long hex keys and `password=`-style values in free text.
String redactSecrets(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAll(_jwtRegex, '<jwt>')
      .replaceAllMapped(_bearerRegex, (m) => '${m[1]} <redacted>')
      .replaceAllMapped(_assignmentRegex, (m) => '${m[1]}${m[2]}<redacted>')
      .replaceAll(_longHexRegex, '<hex>');
}

/// [redactPath] and [redactSecrets] together, for anything posted publicly.
String redactForSharing(String input) => redactSecrets(redactPath(input));

String? _homeDir() {
  final env = Platform.environment;
  final h = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  if (h == null || h.isEmpty) return null;
  return h.endsWith('/') || h.endsWith(r'\') ? h.substring(0, h.length - 1) : h;
}

final RegExp _posixHomeRegex = RegExp(r'(?:/Users/[^/\s]+|/home/[^/\s]+|/root)/');
final RegExp _windowsHomeRegex = RegExp(r'[A-Za-z]:\\Users\\[^\\\s]+\\');
final RegExp _posixProjectRegex =
    RegExp(r'<home>/(?:[^/\s()]+/)*?(lib|test|bin|integration_test|tool)/');
final RegExp _windowsProjectRegex =
    RegExp(r'<home>\\(?:[^\\\s()]+\\)*?(lib|test|bin|integration_test|tool)\\');
final RegExp _jwtRegex = RegExp(r'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}');
final RegExp _bearerRegex = RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}');
final RegExp _assignmentRegex = RegExp(
  r'''\b((?:password|passwd|pwd|secret|token|access_token|refresh_token|api[_-]?key|access[_-]?key|client[_-]?secret)"?)(\s*[:=]\s*"?)(?!<redacted>)[^\s"',;&}]+''',
  caseSensitive: false,
);
final RegExp _longHexRegex = RegExp(r'\b[A-Fa-f0-9]{40,}\b');
