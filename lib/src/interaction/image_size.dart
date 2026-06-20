import 'dart:io';

/// Reads (width, height) from a PNG's IHDR chunk (big-endian u32 at offsets 16, 20); null if missing or unreadable.
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
