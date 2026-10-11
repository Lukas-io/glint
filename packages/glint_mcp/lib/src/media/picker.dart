import '../perception/scene_node.dart';

/// One photo or video cell of a system photo picker, centered in logical points.
typedef PickerCell = ({String label, double x, double y});

final _cellLabel = RegExp(r'^(Photo|Video|Live Photo|Screenshot|Image|Portrait|Panorama)\b');

/// The photo and video cells of a native picker, newest first: row by row, left to right, as both system pickers lay them out.
List<PickerCell> pickerCells(Iterable<SceneNode> nodes) {
  final cells = <PickerCell>[
    for (final n in nodes)
      if (n.isNativeEnabled == true && n.axFrame != null && _cellLabel.hasMatch(n.textPreview ?? ''))
        (label: n.textPreview!, x: n.axFrame!.x + n.axFrame!.w / 2, y: n.axFrame!.y + n.axFrame!.h / 2),
  ];
  cells.sort((a, b) => (a.y - b.y).abs() > 8 ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  return cells;
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// Whether [label] shows a time within the precision it carries of [at]: Android labels have seconds (`Photo taken on Oct 11, 2026, 1:11:27 AM`), iOS labels the minute (`Photo, October 11, 01:12`).
bool cellShowsTime(String label, DateTime at) {
  final android = RegExp(r'on (\w{3})\w* (\d{1,2}), (\d{4}), (\d{1,2}):(\d\d):(\d\d)\s*([AP]M)?').firstMatch(label);
  if (android != null) {
    var hour = int.parse(android.group(4)!);
    final ampm = android.group(7);
    if (ampm == 'PM' && hour < 12) hour += 12;
    if (ampm == 'AM' && hour == 12) hour = 0;
    final month = _months.indexOf(android.group(1)!.toLowerCase()) + 1;
    if (month == 0) return false;
    final shown = DateTime(int.parse(android.group(3)!), month, int.parse(android.group(2)!), hour,
        int.parse(android.group(5)!), int.parse(android.group(6)!));
    return shown.difference(at).inSeconds.abs() <= 3;
  }
  final ios = RegExp(r'(\d{1,2}):(\d\d)\s*([AP]M)?$').firstMatch(label);
  if (ios == null) return false;
  var hour = int.parse(ios.group(1)!);
  if (ios.group(3) == 'PM' && hour < 12) hour += 12;
  if (ios.group(3) == 'AM' && hour == 12) hour = 0;
  final minutes = hour * 60 + int.parse(ios.group(2)!);
  return (minutes - (at.hour * 60 + at.minute)).abs() <= 1;
}

/// The cell for the seeded asset added at [addedAt]; [laterInSameWindow] is how many other seeded assets were added after it within the label's precision, since those sit ahead of it. Null when no cell fits.
int? cellForAsset(List<PickerCell> cells, DateTime addedAt, {int laterInSameWindow = 0}) {
  final fitting = [for (var i = 0; i < cells.length; i++) if (cellShowsTime(cells[i].label, addedAt)) i];
  if (fitting.isEmpty) return null;
  return fitting[laterInSameWindow.clamp(0, fitting.length - 1)];
}
