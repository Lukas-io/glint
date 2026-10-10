/// One of the 16-block binary rows along the bottom of a test card, bottom row first.
enum StripRow { frame, total, width, height, fps }

/// A corner patch color: its name and RGB.
typedef PatchColor = ({String name, int r, int g, int b});

/// Where a glint test card puts its parts, as fractions of the frame so every size and orientation shares one decoder.
abstract final class TestCardLayout {
  static const patchFraction = 0.1;
  static const rowFraction = 0.02;
  static const stripBits = 16;

  /// Corner patches in card order: top-left, top-right, bottom-left, bottom-right.
  static const patchColors = <PatchColor>[
    (name: 'red', r: 255, g: 0, b: 0),
    (name: 'green', r: 0, g: 255, b: 0),
    (name: 'blue', r: 0, g: 0, b: 255),
    (name: 'yellow', r: 255, g: 255, b: 0),
  ];

  /// Top edge, left edge, width and height of the clean background the flash is read from.
  static const flashProbe = (top: 0.02, left: 0.3, width: 0.4, height: 0.05);

  /// Fraction of the frame height where [row] starts, measured from the top.
  static double rowTop(StripRow row) => 1 - rowFraction * (row.index + 1);

  static String hex(PatchColor c) =>
      '0x${c.r.toRadixString(16).padLeft(2, '0')}${c.g.toRadixString(16).padLeft(2, '0')}${c.b.toRadixString(16).padLeft(2, '0')}';
}
