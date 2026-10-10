import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'host_tools.dart';
import 'testcard_decoder.dart';

/// The tool could not read the file as media.
class MediaUnreadable implements Exception {
  MediaUnreadable(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// Loudness of an audio track; any value ffmpeg did not report is null.
class Loudness {
  const Loudness({this.integratedLufs, this.truePeakDb, this.meanDb, this.maxDb});
  final double? integratedLufs;
  final double? truePeakDb;
  final double? meanDb;
  final double? maxDb;

  Map<String, Object?> toJson() => {
        if (integratedLufs != null) 'integratedLufs': integratedLufs,
        if (truePeakDb != null) 'truePeakDb': truePeakDb,
        if (meanDb != null) 'meanDb': meanDb,
        if (maxDb != null) 'maxDb': maxDb,
      };
}

/// ffprobe's view of a media file.
class MediaProbe {
  MediaProbe({
    required this.path,
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationSec,
    this.fps,
    this.videoCodec,
    this.bitrate,
    this.rotation = 0,
    this.audioCodec,
    this.audioChannels,
    this.audioSampleRate,
    this.audioStart = 0,
    this.frameCount,
  });

  final String path;
  final int sizeBytes;
  final int? width;
  final int? height;
  final double? durationSec;
  final double? fps;
  final String? videoCodec;
  final int? bitrate;

  /// Clockwise degrees a player turns the stored frames.
  final int rotation;
  final String? audioCodec;
  final int? audioChannels;
  final int? audioSampleRate;
  final double audioStart;
  final int? frameCount;

  bool get hasVideo => width != null;
  bool get hasAudio => audioCodec != null;
  bool get quarterTurn => rotation == 90 || rotation == 270;

  /// Width and height a viewer sees after the rotation tag is applied.
  ({int w, int h})? get displayed => hasVideo ? (w: quarterTurn ? height! : width!, h: quarterTurn ? width! : height!) : null;

  String get kind => hasVideo ? (durationSec == null || (frameCount ?? 2) <= 1 ? 'photo' : 'video') : 'audio';

  Map<String, Object?> toJson() => {
        'kind': kind,
        'path': path,
        'sizeBytes': sizeBytes,
        if (hasVideo) ...{
          'width': width,
          'height': height,
          if (durationSec != null) 'durationSec': double.parse(durationSec!.toStringAsFixed(3)),
          if (fps != null) 'fps': double.parse(fps!.toStringAsFixed(3)),
          'codec': videoCodec,
          if (bitrate != null) 'bitrate': bitrate,
          'rotation': rotation,
        },
        if (!hasVideo && durationSec != null) 'durationSec': double.parse(durationSec!.toStringAsFixed(3)),
        if (hasAudio) 'audio': {'codec': audioCodec, 'channels': audioChannels, 'sampleRate': audioSampleRate},
      };
}

double? _number(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

double? _fraction(Object? v) {
  if (v is! String) return null;
  final parts = v.split('/');
  final n = double.tryParse(parts.first);
  final d = parts.length > 1 ? double.tryParse(parts[1]) : 1;
  return n == null || d == null || d == 0 ? null : n / d;
}

int _clockwiseRotation(Map<String, Object?> stream) {
  var counterClockwise = 0.0;
  for (final side in (stream['side_data_list'] as List? ?? const [])) {
    final r = _number((side as Map)['rotation']);
    if (r != null) counterClockwise = r;
  }
  final tag = _number((stream['tags'] as Map?)?['rotate']);
  if (counterClockwise == 0 && tag != null) counterClockwise = -tag;
  return ((-counterClockwise).round() % 360 + 360) % 360;
}

/// Reads [path] with ffprobe; throws [MissingHostTool] or [MediaUnreadable].
Future<MediaProbe> probeMedia(String path) async {
  final run = await runHost(requireHostBinary('ffprobe'),
      ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path],
      timeout: const Duration(seconds: 60));
  if (!run.ok) throw MediaUnreadable(run.errTail());
  final json = jsonDecode(run.text) as Map<String, Object?>;
  final streams = (json['streams'] as List? ?? const []).cast<Map<String, Object?>>();
  final format = (json['format'] as Map?)?.cast<String, Object?>() ?? const {};
  Map<String, Object?>? pick(String type, {bool skipStills = false}) {
    for (final s in streams) {
      if (s['codec_type'] != type) continue;
      if (skipStills && (s['disposition'] as Map?)?['attached_pic'] == 1) continue;
      return s;
    }
    return null;
  }

  final video = pick('video', skipStills: true);
  final audio = pick('audio');
  if (video == null && audio == null) throw MediaUnreadable('no video or audio stream in the file');
  return MediaProbe(
    path: path,
    sizeBytes: File(path).lengthSync(),
    width: (video?['width'] as num?)?.toInt(),
    height: (video?['height'] as num?)?.toInt(),
    durationSec: _number(video?['duration']) ?? _number(format['duration']),
    fps: _fraction(video?['avg_frame_rate']) ?? _fraction(video?['r_frame_rate']),
    videoCodec: video?['codec_name'] as String?,
    bitrate: _number(video?['bit_rate'])?.round() ?? _number(format['bit_rate'])?.round(),
    rotation: video == null ? 0 : _clockwiseRotation(video),
    audioCodec: audio?['codec_name'] as String?,
    audioChannels: (audio?['channels'] as num?)?.toInt(),
    audioSampleRate: _number(audio?['sample_rate'])?.round(),
    audioStart: _number(audio?['start_time']) ?? 0,
    frameCount: int.tryParse('${video?['nb_frames']}'),
  );
}

double? _firstNumber(String text, RegExp pattern) {
  final m = pattern.allMatches(text).lastOrNull;
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// Measures the loudness of the audio track with ffmpeg's ebur128 and volumedetect filters; null when it cannot be read.
Future<Loudness?> measureLoudness(String path) async {
  final run = await runHost(
      requireHostBinary('ffmpeg'), ['-hide_banner', '-nostats', '-i', path, '-vn', '-af', 'ebur128=peak=true:framelog=quiet,volumedetect', '-f', 'null', '-'],
      timeout: const Duration(minutes: 3));
  if (!run.ok) return null;
  final log = run.err;
  final summary = log.contains('Summary:') ? log.substring(log.lastIndexOf('Summary:')) : log;
  double? clean(double? v) => v == null || v.isInfinite ? null : v;
  return Loudness(
    integratedLufs: clean(_firstNumber(summary, RegExp(r'I:\s+(-?[\d.]+|-inf)\s+LUFS'))),
    truePeakDb: clean(_firstNumber(summary, RegExp(r'Peak:\s+(-?[\d.]+|-inf)\s+dBFS'))),
    meanDb: clean(_firstNumber(log, RegExp(r'mean_volume:\s+(-?[\d.]+|-inf) dB'))),
    maxDb: clean(_firstNumber(log, RegExp(r'max_volume:\s+(-?[\d.]+|-inf) dB'))),
  );
}

/// The decoded verdict on a glint test card file.
class CardVerdict {
  CardVerdict({
    required this.transform,
    required this.originalWidth,
    required this.originalHeight,
    required this.currentWidth,
    required this.currentHeight,
    required this.total,
    required this.fps,
    required this.stats,
    required this.audioOffsetMs,
    required this.hasAudio,
    required this.photo,
  });

  final CardTransform transform;
  final int originalWidth;
  final int originalHeight;
  final int currentWidth;
  final int currentHeight;
  final int total;
  final int fps;
  final FrameStats stats;
  final int? audioOffsetMs;
  final bool hasAudio;
  final bool photo;

  String get scaleWords {
    final from = '${originalWidth}x$originalHeight';
    final to = '${currentWidth}x$currentHeight';
    if (currentWidth == originalWidth && currentHeight == originalHeight) return 'full size $from';
    final sameAspect = (currentWidth * originalHeight - currentHeight * originalWidth).abs() <= originalHeight + originalWidth;
    if (!sameAspect) return 'resized $from to $to (aspect changed)';
    return '${currentWidth < originalWidth ? 'downscaled' : 'upscaled'} $from to $to';
  }

  String get audioWords {
    if (photo) return '';
    if (!hasAudio) return 'no audio track';
    final ms = audioOffsetMs;
    if (ms == null) return 'audio beeps not found';
    if (ms.abs() <= 20) return 'audio in sync ($ms ms)';
    return 'audio ${ms.abs()} ms ${ms > 0 ? 'late' : 'early'}';
  }

  /// One plain sentence, e.g. `testcard: rotated 90, not mirrored, downscaled 1080x1920 to 360x640, 180 of 180 frames, audio 40 ms late`.
  String get summary => [
        'testcard: ${transform.describe}',
        scaleWords,
        photo ? 'frame ${stats.first} of $total' : stats.describe(total),
        if (audioWords.isNotEmpty) audioWords,
      ].join(', ');

  Map<String, Object?> toJson() => {
        'rotation': transform.rotation,
        'mirrored': transform.mirrored,
        'original': {'width': originalWidth, 'height': originalHeight, 'fps': fps, 'frames': total},
        'current': {'width': currentWidth, 'height': currentHeight},
        'scale': double.parse((currentWidth / originalWidth).toStringAsFixed(4)),
        'frames': stats.toJson(total),
        if (audioOffsetMs != null) 'audioOffsetMs': audioOffsetMs,
      };
}

Future<HostRun> _decodeStrips(String ffmpeg, String path, String graph) async {
  List<String> args(List<String> pace) =>
      ['-v', 'error', '-i', path, '-filter_complex', graph, '-map', '[v]', ...pace, '-pix_fmt', 'gray', '-f', 'rawvideo', '-'];
  final first = await runHost(ffmpeg, args(['-fps_mode', 'passthrough']), timeout: const Duration(minutes: 10));
  if (first.ok || !first.err.contains('fps_mode')) return first;
  return runHost(ffmpeg, args(['-vsync', '0']), timeout: const Duration(minutes: 10));
}

String _stripGraph(CardTransform t) {
  const rows = 5;
  final undo = t.undoFilter;
  final labels = [for (var i = 0; i < rows; i++) 'a$i', 'af'];
  final chains = <String>[
    '[0:v]${undo.isEmpty ? '' : '$undo,'}split=${labels.length}${labels.map((l) => '[$l]').join()}',
    for (var i = 0; i < rows; i++)
      '[a$i]crop=iw*0.8:ih*0.01:iw*0.1:ih*${(1 - 0.02 * (i + 1) + 0.005).toStringAsFixed(3)},scale=16:1:flags=area,format=gray[r$i]',
    '[af]crop=iw*0.4:ih*0.05:iw*0.3:ih*0.02,scale=16:1:flags=area,format=gray[rf]',
    '${[for (var i = 0; i < rows; i++) '[r$i]'].join()}[rf]vstack=inputs=${rows + 1}[v]',
  ];
  return chains.join(';');
}

/// Frame times from ffprobe, or null when they cannot be read.
Future<List<double>?> _frameTimes(String path) async {
  final run = await runHost(
      requireHostBinary('ffprobe'),
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'csv=p=0', path],
      timeout: const Duration(minutes: 3));
  if (!run.ok) return null;
  return [for (final l in run.text.split('\n')) if (double.tryParse(l.trim().split(',').first) case final t?) t];
}

/// The beep times of the audio track, on the container timeline, or null when it cannot be decoded.
Future<List<double>?> _beepTimes(String path, MediaProbe probe) async {
  final run = await runHost(requireHostBinary('ffmpeg'), ['-v', 'error', '-i', path, '-vn', '-ac', '1', '-ar', '16000', '-f', 's16le', '-'],
      timeout: const Duration(minutes: 3));
  if (!run.ok) return null;
  final bytes = Uint8List.fromList(run.out);
  final samples = bytes.buffer.asInt16List(0, bytes.length ~/ 2);
  return [for (final t in beepOnsets(samples, 16000)) t + probe.audioStart];
}

/// Reads the card's corner patches, strips and flash from [path]; null when the file is not a glint test card.
Future<CardVerdict?> decodeTestCard(String path, MediaProbe probe, {PhaseReporter? phases}) async {
  if (!probe.hasVideo) return null;
  final ffmpeg = requireHostBinary('ffmpeg');
  final corner = await runHost(
      ffmpeg, ['-v', 'error', '-i', path, '-frames:v', '1', '-vf', 'scale=100:100:flags=area', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
      timeout: const Duration(minutes: 1));
  if (!corner.ok || corner.out.length < 30000) return null;
  List<int> pixel(int x, int y) => corner.out.sublist((y * 100 + x) * 3, (y * 100 + x) * 3 + 3);
  final transform = cardTransformFromCorners([pixel(5, 5), pixel(94, 5), pixel(5, 94), pixel(94, 94)]);
  if (transform == null) return null;

  Future<T> step<T>(String phase, Future<T> Function() body) => phases == null ? body() : phases.during(phase, body);
  final strips = await step('reading test card frames', () => _decodeStrips(ffmpeg, path, _stripGraph(transform)));
  if (!strips.ok) throw MediaUnreadable('decoding the test card failed: ${strips.errTail()}');
  final readings = StripReadings.parse(strips.out);
  if (readings == null || !readings.plausible) return null;

  final photo = probe.kind == 'photo' || readings.frameIndex.length == 1;
  int? offset;
  if (!photo && probe.hasAudio) {
    final times = await step('measuring audio offset', () => _frameTimes(path));
    final beeps = await step('listening for beeps', () => _beepTimes(path, probe));
    if (times != null && beeps != null) {
      final aligned = times.length == readings.flash.length ? times : [for (var i = 0; i < readings.flash.length; i++) i / readings.fps];
      offset = audioOffsetMs(flashStarts(readings.flash, aligned), beeps);
    }
  }
  final shown = probe.displayed!;
  final quarter = transform.rotation == 90 || transform.rotation == 270;
  return CardVerdict(
    transform: transform,
    originalWidth: readings.width,
    originalHeight: readings.height,
    currentWidth: quarter ? shown.h : shown.w,
    currentHeight: quarter ? shown.w : shown.h,
    total: readings.total,
    fps: readings.fps,
    stats: frameStats(readings.frameIndex, readings.total),
    audioOffsetMs: offset,
    hasAudio: probe.hasAudio,
    photo: photo,
  );
}

/// A frame time asked for: seconds, or one of start, middle, end.
typedef FrameAt = ({String label, double? seconds, bool end});

/// Parses a `frames` entry (a number, a numeric string, `start`, `middle` or `end`), or null when it is none of those.
FrameAt? parseFrameAt(Object? raw, double? durationSec) {
  final text = '$raw'.trim().toLowerCase();
  final seconds = double.tryParse(text);
  if (seconds != null) return seconds < 0 ? null : (label: _secondsLabel(seconds), seconds: seconds, end: false);
  return switch (text) {
    'start' => (label: 'start', seconds: 0, end: false),
    'middle' || 'mid' => (label: 'middle', seconds: (durationSec ?? 0) / 2, end: false),
    'end' => (label: 'end', seconds: null, end: true),
    _ => null,
  };
}

String _secondsLabel(double s) => '${s.toStringAsFixed(s == s.roundToDouble() ? 0 : 2)}s';

/// Extracts the frame at [at] to [out] as a PNG; false when the file has no frame there.
Future<bool> extractFrame(String path, FrameAt at, String out) async {
  final file = File(out);
  if (file.existsSync()) file.deleteSync();
  final args = [
    '-y', '-hide_banner', '-loglevel', 'error',
    if (at.end) ...['-sseof', '-0.25'] else ...['-ss', '${at.seconds}'],
    '-i', path, '-an', if (at.end) ...['-update', '1'], '-frames:v', at.end ? '1000' : '1', out,
  ];
  final run = await runHost(requireHostBinary('ffmpeg'), args, timeout: const Duration(minutes: 1));
  return run.ok && file.existsSync() && file.lengthSync() > 0;
}
