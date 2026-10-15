import 'dart:convert';
import 'dart:io';

import 'shipped_files.dart';

/// One line of text found on a screenshot, with its box in image pixels.
typedef OcrLine = ({String text, double x, double y, double w, double h});

/// The OCR helper's Swift source relative to glint's package root.
const String kOcrSource = 'native/ios_ocr/ocr.swift';

/// Raised when the helper cannot be built or run.
class OcrError implements Exception {
  OcrError(this.message, [this.detail]);
  final String message;
  final String? detail;
  @override
  String toString() => 'OcrError: $message${detail == null ? '' : ' ($detail)'}';
}

/// Text on [image] read with macOS Vision, through a small helper compiled from [kOcrSource] on first use and cached by source hash.
Future<List<OcrLine>> readText(String image) async {
  final helper = await _helper();
  final r = await Process.run(helper, [image]);
  if (r.exitCode != 0) throw OcrError('the OCR helper failed', '${r.stderr}'.trim());
  return [
    for (final m in (jsonDecode('${r.stdout}') as List).cast<Map<String, Object?>>())
      (
        text: m['text']! as String,
        x: (m['x']! as num).toDouble(),
        y: (m['y']! as num).toDouble(),
        w: (m['w']! as num).toDouble(),
        h: (m['h']! as num).toDouble(),
      ),
  ];
}

Future<String> _helper() async {
  final source = _locateSource();
  if (source == null) {
    throw OcrError('the OCR helper source is not part of this glint install', 'looked for $kOcrSource');
  }
  var h = 0x811c9dc5;
  for (final b in File(source).readAsBytesSync()) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  final out = '${Platform.environment['HOME'] ?? '.'}/.glint/bin/glint-ocr-${h.toRadixString(16)}';
  if (File(out).existsSync()) return out;
  Directory(File(out).parent.path).createSync(recursive: true);
  final r = await Process.run('xcrun', ['swiftc', '-O', source, '-o', out]);
  if (r.exitCode != 0 || !File(out).existsSync()) {
    throw OcrError('could not build the OCR helper with the Xcode toolchain',
        '${r.stderr}'.trim().split('\n').take(3).join(' | '));
  }
  return out;
}

String? _locateSource() => shippedPath(kOcrSource);
