import 'dart:convert';
import 'dart:io';

/// One frame the sampler kept: its file and its time from recording start.
typedef SampledFrame = ({String path, int atMs});

/// A kept frame plus how long it stayed on screen before the next one.
class RecordedFrame {
  RecordedFrame(
      {required this.index,
      required this.path,
      required this.atMs,
      required this.holdMs});
  final int index;
  final String path;
  final int atMs;
  final int holdMs;

  Map<String, Object?> toJson() =>
      {'index': index, 'path': path, 'atMs': atMs, 'holdMs': holdMs};
}

/// Parsed output of the bridge `frames` command.
class FrameLines {
  FrameLines(
      {required this.frames,
      required this.durationMs,
      required this.sampled,
      required this.capped});
  final List<SampledFrame> frames;
  final int? durationMs;
  final int sampled;
  final bool capped;
}

/// Parses the bridge's JSON lines; non-JSON lines and unknown keys are ignored.
FrameLines parseFrameLines(String stdout) {
  final frames = <SampledFrame>[];
  int? durationMs;
  var sampled = 0;
  var capped = false;
  for (final line in const LineSplitter().convert(stdout)) {
    final t = line.trim();
    if (t.isEmpty || !t.startsWith('{')) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(t);
    } on Object {
      continue;
    }
    if (decoded is! Map) continue;
    if (decoded['done'] == true) {
      durationMs = decoded['durationMs'] as int?;
      sampled = (decoded['sampled'] as int?) ?? sampled;
      capped = decoded['capped'] == true;
      continue;
    }
    final path = decoded['path'] as String?;
    final atMs = decoded['atMs'] as int?;
    if (path != null && atMs != null) frames.add((path: path, atMs: atMs));
  }
  return FrameLines(
      frames: frames, durationMs: durationMs, sampled: sampled, capped: capped);
}

/// Assigns each frame a holdMs (next frame's atMs minus its own); the last holds until [endMs].
List<RecordedFrame> withHoldMs(List<SampledFrame> frames, {required int endMs}) {
  final out = <RecordedFrame>[];
  for (var i = 0; i < frames.length; i++) {
    final at = frames[i].atMs;
    final next = i + 1 < frames.length ? frames[i + 1].atMs : endMs;
    out.add(RecordedFrame(
      index: i + 1,
      path: frames[i].path,
      atMs: at,
      holdMs: (next - at).clamp(0, 1 << 30),
    ));
  }
  return out;
}

/// A human summary: "3 distinct frames over 1.2 s: #1 0 ms (held 210 ms), …".
String describeFrames(List<RecordedFrame> frames, int wallMs,
    {required bool distinctOnly}) {
  final s = (wallMs / 1000).toStringAsFixed(1);
  if (frames.isEmpty) return 'no frames captured over $s s';
  final kind = distinctOnly ? 'distinct frame' : 'frame';
  final head = '${frames.length} $kind${frames.length == 1 ? '' : 's'} over $s s';
  final bits = frames
      .map((f) => '#${f.index} ${f.atMs} ms (held ${f.holdMs} ms)')
      .join(', ');
  return '$head: $bits';
}

/// Extracts frames from a recorded video with the bridge on macOS, ffmpeg elsewhere.
class FrameExtractor {
  FrameExtractor(
      {this.bridgePath, this.ffmpegPath = 'ffmpeg', this.run = Process.run});
  final String? bridgePath;
  final String ffmpegPath;
  final Future<ProcessResult> Function(String, List<String>) run;

  Future<FrameExtraction> extract({
    required String video,
    required String outDir,
    required int everyMs,
    required int maxFrames,
    required bool distinctOnly,
  }) async {
    if (bridgePath != null && File(bridgePath!).existsSync()) {
      final r = await run(bridgePath!,
          ['frames', video, outDir, '$everyMs', '$maxFrames', distinctOnly ? '1' : '0']);
      if (r.exitCode != 0) {
        return FrameExtraction(
            error: 'bridge frames exited ${r.exitCode}: '
                '${(r.stderr as String?)?.trim() ?? ''}');
      }
      final parsed = parseFrameLines((r.stdout as String?) ?? '');
      return FrameExtraction(
        frames: parsed.frames,
        durationMs: parsed.durationMs,
        capped: parsed.capped,
        tool: 'bridge',
      );
    }
    return _ffmpegExtract(video, outDir, everyMs, maxFrames);
  }

  Future<FrameExtraction> _ffmpegExtract(
      String video, String outDir, int everyMs, int maxFrames) async {
    Directory(outDir).createSync(recursive: true);
    final ProcessResult r;
    try {
      r = await run(ffmpegPath, [
        '-loglevel', 'error', '-i', video, //
        '-vf', 'fps=1000/$everyMs', '-vsync', '0',
        '$outDir/frame-%04d.png',
      ]);
    } on Object catch (e) {
      return FrameExtraction(
          error: 'no bridge and ffmpeg unavailable ($e); video kept, no frames');
    }
    if (r.exitCode != 0) {
      return FrameExtraction(
          error: 'ffmpeg exited ${r.exitCode}: ${(r.stderr as String?)?.trim() ?? ''}');
    }
    final files = Directory(outDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    // Thin to maxFrames by stride; ffmpeg gives fixed samples, not distinct.
    final stride = files.isEmpty ? 1 : (files.length / maxFrames).ceil();
    final kept = <SampledFrame>[];
    for (var i = 0; i < files.length; i += stride) {
      kept.add((path: files[i].path, atMs: i * everyMs));
    }
    return FrameExtraction(
      frames: kept,
      capped: files.length > kept.length,
      tool: 'ffmpeg',
      warnings: const [
        'ffmpeg fallback: distinctOnly not applied, frames are fixed samples',
      ],
    );
  }
}

/// Result of a frame extraction: the kept frames or an error, plus which tool ran.
class FrameExtraction {
  FrameExtraction({
    this.frames = const [],
    this.durationMs,
    this.capped = false,
    this.tool,
    this.warnings = const [],
    this.error,
  });
  final List<SampledFrame> frames;
  final int? durationMs;
  final bool capped;
  final String? tool;
  final List<String> warnings;
  final String? error;
}
