import 'scene_node.dart';

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
