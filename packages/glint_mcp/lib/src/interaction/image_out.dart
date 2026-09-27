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
