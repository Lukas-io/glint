import 'dart:io';

/// Reads width/height from a PNG's IHDR chunk (big-endian, at fixed offsets
/// 16 and 20 after the 8-byte signature + chunk header). Returns null if the
/// file is missing or not a readable PNG.
(int, int)? pngSize(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 24) return null;
    int u32(int o) =>
        (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) |
        bytes[o + 3];
    return (u32(16), u32(20));
  } on Object {
    return null;
  }
}
