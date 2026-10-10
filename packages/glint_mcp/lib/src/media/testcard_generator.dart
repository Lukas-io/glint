import 'dart:io';

import 'testcard_layout.dart';

/// What a generated test card looks like; [frames] is the whole clip, a photo is one frame at [firstFrame].
class TestCardSpec {
  const TestCardSpec({
    this.width = 1080,
    this.height = 1920,
    this.fps = 30,
    this.durationSec = 6,
    this.rotation = 0,
    this.photo = false,
    this.firstFrame = 0,
    this.photoCount = 1,
  });

  final int width;
  final int height;
  final int fps;
  final num durationSec;

  /// Clockwise degrees a player must turn the stored frames to show the card upright.
  final int rotation;
  final bool photo;
  final int firstFrame;
  final int photoCount;

  int get frames => photo ? photoCount : (durationSec * fps).round();
  int get gridPx => (width < height ? width : height) ~/ 18;

  /// The reason this spec cannot be generated, or null.
  String? get problem {
    if (width < 64 || height < 64 || width.isOdd || height.isOdd) return 'size must be even and at least 64x64, got ${width}x$height';
    if (width > 4096 || height > 4096) return 'size above 4096 is not supported, got ${width}x$height';
    if (fps < 1 || fps > 120) return 'fps must be 1 to 120, got $fps';
    if (!photo && (durationSec <= 0 || frames < 1)) return 'durationSec must be positive';
    if (frames > 65535) return 'a card holds at most 65535 frames, got $frames (shorten durationSec or lower fps)';
    if (!const {0, 90, 180, 270}.contains(rotation)) return 'rotation must be 0, 90, 180 or 270, got $rotation';
    return null;
  }
}

/// A font the drawtext filter can load, or null when none is installed.
String? findCardFont() {
  const candidates = [
    '/System/Library/Fonts/Menlo.ttc',
    '/System/Library/Fonts/Monaco.ttf',
    '/Library/Fonts/Arial.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
    '/usr/share/fonts/dejavu/DejaVuSansMono-Bold.ttf',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

String _box(num x, num y, num w, num h, String color, {String? enable}) =>
    'drawbox=x=$x:y=$y:w=$w:h=$h:color=$color:t=fill${enable == null ? '' : ":enable='$enable'"}';

/// The lavfi graph that draws the card: grid, flash, corner patches, binary strips, frame number and timecode.
String testCardGraph(TestCardSpec s, {required String fontFile}) {
  final w = s.width;
  final h = s.height;
  final pw = (w * TestCardLayout.patchFraction).round();
  final ph = (h * TestCardLayout.patchFraction).round();
  final first = s.firstFrame;
  final frameExpr = first == 0 ? 'n' : 'n+$first';
  final parts = <String>[
    'color=c=0x202020:s=${w}x$h:r=${s.fps}:d=${s.photo ? 1 : s.durationSec}',
    'drawgrid=w=${s.gridPx}:h=${s.gridPx}:t=2:c=white@0.15',
    if (!s.photo) _box(0, 0, w, (h * 0.9).round(), 'white', enable: 'eq(mod(n,${s.fps}),0)'),
    _box(0, 0, pw, ph, TestCardLayout.hex(TestCardLayout.patchColors[0])),
    _box(w - pw, 0, pw, ph, TestCardLayout.hex(TestCardLayout.patchColors[1])),
    _box(0, h - ph, pw, ph, TestCardLayout.hex(TestCardLayout.patchColors[2])),
    _box(w - pw, h - ph, pw, ph, TestCardLayout.hex(TestCardLayout.patchColors[3])),
  ];
  final stripWidth = w - 2 * pw;
  double blockX(int i) => pw + (i * stripWidth / TestCardLayout.stripBits).roundToDouble();
  int rowY(StripRow row) => (h * TestCardLayout.rowTop(row)).round();
  int rowHeight(StripRow row) => (h * (TestCardLayout.rowTop(row) + TestCardLayout.rowFraction)).round() - rowY(row);
  final staticValues = {
    StripRow.total: s.frames,
    StripRow.width: w,
    StripRow.height: h,
    StripRow.fps: s.fps,
  };
  for (final row in StripRow.values) {
    parts.add(_box(pw, rowY(row), stripWidth, rowHeight(row), 'black'));
  }
  for (var i = 0; i < TestCardLayout.stripBits; i++) {
    final bit = TestCardLayout.stripBits - 1 - i;
    final x = blockX(i).round();
    final bw = blockX(i + 1).round() - x;
    for (final entry in staticValues.entries) {
      if ((entry.value >> bit) & 1 == 1) parts.add(_box(x, rowY(entry.key), bw, rowHeight(entry.key), 'white'));
    }
    parts.add(_box(x, rowY(StripRow.frame), bw, rowHeight(StripRow.frame), 'white', enable: 'gt(bitand($frameExpr,${1 << bit}),0)'));
  }
  final side = w < h ? w : h;
  String text(String body, double yFraction, double sizeFraction) =>
      "drawtext=fontfile='$fontFile':text='$body':x=(w-text_w)/2:y=h*$yFraction:fontsize=${(side * sizeFraction).round()}"
      ':fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=${(side * 0.015).round()}';
  parts.add(text('glint testcard ${w}x$h ${s.fps}fps grid ${s.gridPx}px', 0.13, 0.04));
  parts.add(text('%{eif\\:$frameExpr\\:d\\:5}', 0.42, 0.16));
  if (!s.photo) parts.add(text('%{pts\\:hms}', 0.58, 0.07));
  return parts.join(',');
}

/// The one-second beep train: 1 kHz for 50 ms at every whole second, silence between.
String testCardAudioGraph(TestCardSpec s) =>
    "aevalsrc='if(lt(mod(t,1),0.05),0.8*sin(2*PI*1000*t),0)':s=48000:d=${s.durationSec}";

/// The ffmpeg arguments that render a video card to [out] (before any rotation tag).
List<String> testCardVideoArgs(TestCardSpec s, String out, {required String fontFile}) => [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', testCardGraph(s, fontFile: fontFile),
      '-f', 'lavfi', '-i', testCardAudioGraph(s),
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '14', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
      '-movflags', '+faststart', out,
    ];

/// The ffmpeg arguments that render one photo card (frame [TestCardSpec.firstFrame]) to a PNG or JPEG at [out].
List<String> testCardPhotoArgs(TestCardSpec s, String out, {required String fontFile}) => [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', testCardGraph(s, fontFile: fontFile),
      '-frames:v', '1', if (out.endsWith('.jpg')) ...['-q:v', '2'], out,
    ];

/// The ffmpeg arguments that copy [input] to [out] tagged to display turned [clockwise] degrees.
List<String> rotationTagArgs(String input, String out, int clockwise) => [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-display_rotation', '${(360 - clockwise) % 360}', '-i', input,
      '-c', 'copy', '-movflags', '+faststart', out,
    ];
