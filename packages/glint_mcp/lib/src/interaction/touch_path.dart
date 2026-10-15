/// One sample of a touch: physical pixels, and ms after the touch began.
typedef TouchPoint = ({int x, int y, int ms});

/// A straight drag from ([x1], [y1]) to ([x2], [y2]) over [durationMs] in frame-sized steps, after holding still for [holdMs].
List<TouchPoint> dragPath(int x1, int y1, int x2, int y2, {required int durationMs, int holdMs = 0, int frameMs = 16}) {
  final steps = (durationMs / frameMs).ceil().clamp(2, 400);
  return [
    (x: x1, y: y1, ms: 0),
    if (holdMs > 0) (x: x1, y: y1, ms: holdMs),
    for (var i = 1; i <= steps; i++)
      (
        x: (x1 + (x2 - x1) * i / steps).round(),
        y: (y1 + (y2 - y1) * i / steps).round(),
        ms: holdMs + (durationMs * i / steps).round(),
      ),
  ];
}
