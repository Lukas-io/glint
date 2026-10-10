import 'dart:math' as math;
import 'dart:typed_data';

import 'testcard_layout.dart';

/// How a file has turned a test card: [rotation] clockwise degrees applied after a horizontal mirror when [mirrored].
class CardTransform {
  const CardTransform(this.rotation, this.mirrored);
  final int rotation;
  final bool mirrored;

  /// Filters that put a decoded frame back upright.
  String get undoFilter => [
        switch (rotation) {
          90 => 'transpose=2',
          180 => 'hflip,vflip',
          270 => 'transpose=1',
          _ => null,
        },
        if (mirrored) 'hflip',
      ].whereType<String>().join(',');

  /// The orientation in plain words, e.g. `rotated 90, not mirrored`.
  String get describe => switch ((mirrored, rotation)) {
        (true, 0) => 'rotated 0, mirrored horizontally',
        (true, 180) => 'rotated 0, flipped vertically',
        (true, _) => 'mirrored horizontally, then rotated $rotation',
        _ => 'rotated $rotation, not mirrored',
      };
}

typedef _Corner = ({int x, int y});

const _cornerSpots = <_Corner>[(x: 0, y: 0), (x: 1, y: 0), (x: 0, y: 1), (x: 1, y: 1)];

const _transforms = <(CardTransform, _Corner, _Corner)>[
  (CardTransform(0, false), (x: 1, y: 0), (x: 0, y: 1)),
  (CardTransform(90, false), (x: 0, y: 1), (x: -1, y: 0)),
  (CardTransform(180, false), (x: -1, y: 0), (x: 0, y: -1)),
  (CardTransform(270, false), (x: 0, y: -1), (x: 1, y: 0)),
  (CardTransform(0, true), (x: -1, y: 0), (x: 0, y: 1)),
  (CardTransform(90, true), (x: 0, y: -1), (x: -1, y: 0)),
  (CardTransform(180, true), (x: 1, y: 0), (x: 0, y: -1)),
  (CardTransform(270, true), (x: 0, y: 1), (x: 1, y: 0)),
];

int _nearestPatch(int r, int g, int b) {
  var best = -1;
  var bestDistance = 1 << 30;
  for (var i = 0; i < TestCardLayout.patchColors.length; i++) {
    final c = TestCardLayout.patchColors[i];
    final d = (r - c.r) * (r - c.r) + (g - c.g) * (g - c.g) + (b - c.b) * (b - c.b);
    if (d < bestDistance) {
      bestDistance = d;
      best = i;
    }
  }
  return bestDistance <= 110 * 110 ? best : -1;
}

/// The transform that moved the four corner patches to [rgb] (top-left, top-right, bottom-left, bottom-right samples as r,g,b), or null when the frame is not a glint test card.
CardTransform? cardTransformFromCorners(List<List<int>> rgb) {
  final spotOf = <int, _Corner>{};
  for (var i = 0; i < 4; i++) {
    final patch = _nearestPatch(rgb[i][0], rgb[i][1], rgb[i][2]);
    if (patch < 0 || spotOf.containsKey(patch)) return null;
    spotOf[patch] = _cornerSpots[i];
  }
  final red = spotOf[0]!;
  final green = spotOf[1]!;
  final blue = spotOf[2]!;
  final u = (x: green.x - red.x, y: green.y - red.y);
  final v = (x: blue.x - red.x, y: blue.y - red.y);
  for (final (t, tu, tv) in _transforms) {
    if (tu == u && tv == v) return t;
  }
  return null;
}

/// What the binary strips and flash probe of every decoded frame say, read from gray samples (16 per strip row, then 16 for the flash probe).
class StripReadings {
  StripReadings._(this.frameIndex, this.flash, this.total, this.width, this.height, this.fps);

  /// The frame index each decoded frame shows.
  final List<int> frameIndex;

  /// Whether each decoded frame is the white flash.
  final List<bool> flash;
  final int total;
  final int width;
  final int height;
  final int fps;

  static const _rowCount = 5;
  static const bytesPerFrame = (_rowCount + 1) * TestCardLayout.stripBits;

  /// Parses [bytes], one [bytesPerFrame] block per decoded frame; null when there is no whole frame.
  static StripReadings? parse(List<int> bytes) {
    final frames = bytes.length ~/ bytesPerFrame;
    if (frames == 0) return null;
    const bits = TestCardLayout.stripBits;
    int rowValue(int frame, int row) {
      var value = 0;
      for (var i = 0; i < bits; i++) {
        value = value << 1 | (bytes[frame * bytesPerFrame + row * bits + i] > 127 ? 1 : 0);
      }
      return value;
    }

    int staticValue(StripRow row) {
      var value = 0;
      for (var i = 0; i < bits; i++) {
        var sum = 0;
        for (var f = 0; f < frames; f++) {
          sum += bytes[f * bytesPerFrame + row.index * bits + i];
        }
        value = value << 1 | (sum / frames > 127 ? 1 : 0);
      }
      return value;
    }

    final probeRow = StripRow.values.length;
    return StripReadings._(
      [for (var f = 0; f < frames; f++) rowValue(f, StripRow.frame.index)],
      [
        for (var f = 0; f < frames; f++)
          [for (var i = 0; i < bits; i++) bytes[f * bytesPerFrame + probeRow * bits + i]].reduce((a, b) => a + b) / bits > 160,
      ],
      staticValue(StripRow.total),
      staticValue(StripRow.width),
      staticValue(StripRow.height),
      staticValue(StripRow.fps),
    );
  }

  bool get plausible => total > 0 && width >= 64 && height >= 64 && fps > 0 && fps <= 240;
}

/// How the frames of a decoded clip compare with the card's own count.
class FrameStats {
  const FrameStats({
    required this.decoded,
    required this.unique,
    required this.first,
    required this.last,
    required this.dropped,
    required this.duplicated,
    required this.trimmedStart,
    required this.trimmedEnd,
  });

  final int decoded;
  final int unique;
  final int first;
  final int last;

  /// Frames missing between the first and last one seen.
  final int dropped;

  /// Decoded frames that repeat an index already seen.
  final int duplicated;
  final int trimmedStart;
  final int trimmedEnd;

  bool get complete => dropped == 0 && duplicated == 0 && trimmedStart == 0 && trimmedEnd == 0;

  /// `180 of 180 frames`, with what is wrong in brackets.
  String describe(int total) {
    final notes = [
      if (dropped > 0) '$dropped dropped',
      if (duplicated > 0) '$duplicated duplicated',
      if (trimmedStart > 0) '$trimmedStart trimmed at start',
      if (trimmedEnd > 0) '$trimmedEnd trimmed at end',
      if (!complete) 'first $first, last $last',
    ];
    return '$unique of $total frames${notes.isEmpty ? '' : ' (${notes.join(', ')})'}';
  }

  Map<String, Object?> toJson(int total) => {
        'expected': total,
        'decoded': decoded,
        'unique': unique,
        'first': first,
        'last': last,
        'dropped': dropped,
        'duplicated': duplicated,
        'trimmedStart': trimmedStart,
        'trimmedEnd': trimmedEnd,
      };
}

/// Counts dropped, duplicated and trimmed frames from the indices read off a clip whose card holds [total] frames.
FrameStats frameStats(List<int> indices, int total) {
  final valid = [for (final i in indices) if (i >= 0 && i < total) i];
  final seen = valid.toSet();
  final first = seen.isEmpty ? 0 : seen.reduce(math.min);
  final last = seen.isEmpty ? 0 : seen.reduce(math.max);
  return FrameStats(
    decoded: indices.length,
    unique: seen.length,
    first: first,
    last: last,
    dropped: seen.isEmpty ? 0 : (last - first + 1) - seen.length,
    duplicated: indices.length - seen.length,
    trimmedStart: seen.isEmpty ? 0 : first,
    trimmedEnd: seen.isEmpty ? 0 : total - 1 - last,
  );
}

/// Seconds at which a beep starts in mono 16-bit [samples] at [rate] Hz, found with 1 ms peak windows; empty when the track is silent.
List<double> beepOnsets(Int16List samples, int rate) {
  final window = math.max(1, rate ~/ 1000);
  final windows = samples.length ~/ window;
  final peaks = List<int>.filled(windows, 0);
  var loudest = 0;
  for (var w = 0; w < windows; w++) {
    var peak = 0;
    for (var i = w * window; i < (w + 1) * window; i++) {
      final a = samples[i].abs();
      if (a > peak) peak = a;
    }
    peaks[w] = peak;
    if (peak > loudest) loudest = peak;
  }
  if (loudest < 1000) return const [];
  final threshold = loudest * 0.25;
  final onsets = <double>[];
  var quietFor = 1 << 20;
  for (var w = 0; w < windows; w++) {
    if (peaks[w] > threshold) {
      if (quietFor >= 100) onsets.add(w * window / rate);
      quietFor = 0;
    } else {
      quietFor++;
    }
  }
  return onsets;
}

/// Seconds at which the flash starts: frames whose probe went white after a normal frame (the first frame counts).
List<double> flashStarts(List<bool> flash, List<double> times) {
  final starts = <double>[];
  for (var i = 0; i < flash.length && i < times.length; i++) {
    if (flash[i] && (i == 0 || !flash[i - 1])) starts.add(times[i]);
  }
  return starts;
}

/// Median of beep time minus flash time (positive: audio late) over beeps within half a second of a flash, in ms; null when none pair up.
int? audioOffsetMs(List<double> flashes, List<double> beeps) {
  final offsets = <double>[];
  for (final f in flashes) {
    double? nearest;
    for (final b in beeps) {
      if ((b - f).abs() < 0.5 && (nearest == null || (b - f).abs() < (nearest - f).abs())) nearest = b;
    }
    if (nearest != null) offsets.add(nearest - f);
  }
  if (offsets.isEmpty) return null;
  offsets.sort();
  return (offsets[offsets.length ~/ 2] * 1000).round();
}
