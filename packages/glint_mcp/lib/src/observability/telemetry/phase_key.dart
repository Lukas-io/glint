final RegExp _safeWord = RegExp(r'^[a-z][a-z_\-]{0,19}$');

/// The key of a bounded subprocess in usage events: its phase name when that is plain words, else just the program.
String usageProcessKey(String executable, String? phase) {
  final named = phase == null ? null : _words(phase.toLowerCase());
  if (named != null) return 'proc:$named';
  final program = executable.split('/').last.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_\-]'), '');
  return 'proc:${program.isEmpty ? 'other' : program}';
}

String? _words(String text) {
  final words = text.split(' ');
  if (words.length > 5 || !words.every(_safeWord.hasMatch)) return null;
  return text;
}
