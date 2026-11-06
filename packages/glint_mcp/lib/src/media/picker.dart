import '../perception/picker_cells.dart';

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
  final fitting = [
    for (var i = 0; i < cells.length; i++)
      if (cellShowsTime(cells[i].label, addedAt)) i
  ];
  if (fitting.isEmpty) return null;
  return fitting[laterInSameWindow.clamp(0, fitting.length - 1)];
}
