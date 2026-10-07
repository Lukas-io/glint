import 'dart:io';

/// An image prepared for the model: its file, pixel size and media type.
typedef ModelImage = ({String path, int width, int height, String mimeType});

/// Target pixel size when the longest side is capped at [maxSize] (0 = no cap); never upscales.
({int width, int height}) modelImageSize(int width, int height, int maxSize) {
  final longest = width > height ? width : height;
  if (maxSize <= 0 || longest <= maxSize) return (width: width, height: height);
  final scale = maxSize / longest;
  return (width: (width * scale).round(), height: (height * scale).round());
}

/// Shrinks and re-encodes [src] for the model (`sips` on macOS, ImageMagick elsewhere); returns the original PNG when no resizer is available or none is needed.
Future<ModelImage> prepareModelImage(
  String src, {
  required int width,
  required int height,
  required int maxSize,
  required String format,
  required int quality,
  Future<ProcessResult> Function(String, List<String>) run = Process.run,
}) async {
  final original = (path: src, width: width, height: height, mimeType: 'image/png');
  final size = modelImageSize(width, height, maxSize);
  final jpeg = format == 'jpeg';
  if (!jpeg && size.width == width) return original;
  final dst = '${src.replaceAll(RegExp(r'\.png$'), '')}-model.${jpeg ? 'jpg' : 'png'}';
  final longest = size.width > size.height ? size.width : size.height;
  try {
    final r = Platform.isMacOS
        ? await run('sips', [
            if (size.width != width) ...['-Z', '$longest'],
            '-s', 'format', jpeg ? 'jpeg' : 'png',
            if (jpeg) ...['-s', 'formatOptions', '$quality'],
            src, '--out', dst,
          ])
        : await run('convert', [
            src,
            if (size.width != width) ...['-resize', '${longest}x$longest'],
            if (jpeg) ...['-quality', '$quality'],
            dst,
          ]);
    if (r.exitCode != 0 || !File(dst).existsSync()) return original;
  } on Object {
    return original;
  }
  return (path: dst, width: size.width, height: size.height, mimeType: jpeg ? 'image/jpeg' : 'image/png');
}

/// Whether two screenshots show a different screen, judged on 32x64 thumbnails with the status bar left out; null when they cannot be compared.
Future<bool?> screensDiffer(
  String a,
  String b, {
  Future<ProcessResult> Function(String, List<String>) run = Process.run,
}) async {
  final ta = await _thumbnail(a, run);
  final tb = await _thumbnail(b, run);
  if (ta == null || tb == null || ta.length != tb.length) return null;
  final skip = ta.length ~/ 16;
  var differing = 0;
  for (var i = skip; i < ta.length; i++) {
    if ((ta[i] - tb[i]).abs() > 8) differing++;
  }
  return differing > (ta.length - skip) * 0.005;
}

/// Grey pixels of [src] shrunk to 32x64, top row first; null when no resizer is available.
Future<List<int>?> _thumbnail(String src, Future<ProcessResult> Function(String, List<String>) run) async {
  final dst = '${src.replaceAll(RegExp(r'\.png$'), '')}-thumb.bmp';
  try {
    final r = Platform.isMacOS
        ? await run('sips', ['-z', '64', '32', '-s', 'format', 'bmp', src, '--out', dst])
        : await run('convert', [src, '-resize', '32x64!', 'BMP3:$dst']);
    if (r.exitCode != 0) return null;
    return _bmpGrey(File(dst).readAsBytesSync());
  } on Object {
    return null;
  } finally {
    try {
      File(dst).deleteSync();
    } on Object {
      // already gone
    }
  }
}

/// Grey values of an uncompressed 24 or 32-bit BMP, top row first.
List<int>? _bmpGrey(List<int> b) {
  if (b.length < 54 || b[0] != 0x42 || b[1] != 0x4D) return null;
  int u32(int o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
  final offset = u32(10);
  final width = u32(18);
  var height = u32(22);
  final topDown = height > 0x7fffffff;
  if (topDown) height = 0x100000000 - height;
  final bytesPerPixel = (b[28] | b[29] << 8) ~/ 8;
  if (bytesPerPixel < 3) return null;
  final stride = (width * bytesPerPixel + 3) & ~3;
  if (offset + stride * height > b.length) return null;
  final out = <int>[];
  for (var row = 0; row < height; row++) {
    final r = topDown ? row : height - 1 - row;
    for (var x = 0; x < width; x++) {
      final p = offset + r * stride + x * bytesPerPixel;
      out.add((b[p] + b[p + 1] + b[p + 2]) ~/ 3);
    }
  }
  return out;
}
