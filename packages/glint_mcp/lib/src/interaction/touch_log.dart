import 'touch_path.dart';

/// One touch glint sent: when its fingers went down, and each finger's path in device pixels.
typedef TouchRecord = ({DateTime at, List<List<TouchPoint>> fingers});

/// The touches glint sent on one device, oldest first, for drawing onto recordings; keeps the last [capacity].
class TouchLog {
  TouchLog({this.capacity = 2000});

  final int capacity;
  final _records = <TouchRecord>[];

  void add(List<List<TouchPoint>> fingers) {
    _records.add((at: DateTime.now(), fingers: fingers));
    if (_records.length > capacity) _records.removeAt(0);
  }

  /// The touches that began between [from] and [to].
  List<TouchRecord> between(DateTime from, DateTime to) => [
        for (final r in _records)
          if (!r.at.isBefore(from) && !r.at.isAfter(to)) r,
      ];
}
