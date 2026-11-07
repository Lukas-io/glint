import 'dart:io';

import 'bounded_process.dart';

/// A Swift helper could not be built with the Xcode toolchain.
class SwiftHelperError implements Exception {
  SwiftHelperError(this.message, this.detail);
  final String message;
  final String detail;
  @override
  String toString() => 'SwiftHelperError: $message ($detail)';
}

/// The helper built from [source], compiled with swiftc on first use and cached under `~/.glint/bin` as `<prefix>-<source hash>`.
Future<String> swiftHelper(String source, String prefix, {String? phase}) async {
  var h = 0x811c9dc5;
  for (final b in File(source).readAsBytesSync()) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  final out = '${Platform.environment['HOME'] ?? '.'}/.glint/bin/$prefix-${h.toRadixString(16)}';
  if (File(out).existsSync()) return out;
  Directory(File(out).parent.path).createSync(recursive: true);
  final r = await runBounded('xcrun', ['swiftc', '-O', source, '-o', out],
      timeout: const Duration(minutes: 5), phase: phase ?? 'building the $prefix helper');
  if (r.exitCode != 0 || !File(out).existsSync()) {
    throw SwiftHelperError('could not build the $prefix helper with the Xcode toolchain',
        '${r.stderr}'.trim().split('\n').take(3).join(' | '));
  }
  return out;
}
