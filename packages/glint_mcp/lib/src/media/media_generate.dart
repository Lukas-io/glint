import 'dart:io';

import 'gallery.dart';
import 'host_tools.dart';
import 'seed_ledger.dart';
import 'testcard_generator.dart';

Future<HostRun> _ffmpeg(List<String> args, PhaseReporter? phases, String phase) async {
  final ffmpeg = requireHostBinary('ffmpeg');
  Future<HostRun> run() => runHost(ffmpeg, args, timeout: const Duration(minutes: 10));
  final result = await (phases == null ? run() : phases.during(phase, run));
  if (!result.ok && result.err.contains("No such filter: 'drawtext'")) {
    throw MissingHostTool('ffmpeg', reason: 'this ffmpeg was built without the drawtext filter (libfreetype), which the test card needs');
  }
  return result;
}

String _generatedPath(String file) => '${mediaDir('generated')}/$file';

/// Renders a test card clip ([TestCardSpec.photo] false) to `generated/<name>.mp4`.
Future<File> generateTestCardVideo(TestCardSpec spec, String name, {PhaseReporter? phases}) async {
  final font = findCardFont() ?? (throw MissingHostTool('font', reason: 'no font file found for the test card text (looked for Menlo and DejaVu)'));
  final out = _generatedPath('$name.mp4');
  final plain = spec.rotation == 0 ? out : _generatedPath('$name.untagged.mp4');
  final render = await _ffmpeg(testCardVideoArgs(spec, plain, fontFile: font), phases, 'rendering the test card video');
  if (!render.ok) throw GalleryError('ffmpeg could not render the test card', render.errTail());
  if (spec.rotation != 0) {
    final tag = await _ffmpeg(rotationTagArgs(plain, out, spec.rotation), phases, 'tagging rotation ${spec.rotation}');
    File(plain).deleteSync();
    if (!tag.ok) throw GalleryError('ffmpeg could not tag the rotation', tag.errTail());
  }
  return File(out);
}

/// Renders photo cards `generated/<name>-<n>.png`, one per frame index from 0.
Future<List<File>> generateTestCardPhotos(TestCardSpec spec, String name, {PhaseReporter? phases}) async {
  final font = findCardFont() ?? (throw MissingHostTool('font', reason: 'no font file found for the test card text (looked for Menlo and DejaVu)'));
  final files = <File>[];
  for (var i = 0; i < spec.photoCount; i++) {
    final one = TestCardSpec(
      width: spec.width,
      height: spec.height,
      fps: spec.fps,
      photo: true,
      firstFrame: i,
      photoCount: spec.photoCount,
    );
    final out = _generatedPath(spec.photoCount == 1 ? '$name.png' : '$name-${i + 1}.png');
    final run = await _ffmpeg(testCardPhotoArgs(one, out, fontFile: font), phases, 'rendering photo ${i + 1} of ${spec.photoCount}');
    if (!run.ok) throw GalleryError('ffmpeg could not render the test card photo', run.errTail());
    files.add(File(out));
  }
  return files;
}

/// Speaks [text] with macOS `say` and encodes it to `generated/<name>.m4a`.
Future<File> generateSpeech(String text, String name, {String? voice, PhaseReporter? phases}) async {
  if (!Platform.isMacOS) throw MissingHostTool('say', reason: 'offline speech needs macOS `say`, which this host does not have');
  final say = requireHostBinary('say');
  final aiff = _generatedPath('$name.aiff');
  final script = File(_generatedPath('$name.txt'))..writeAsStringSync(text);
  Future<HostRun> speak() => runHost(say, [if (voice != null) ...['-v', voice], '-o', aiff, '-f', script.path]);
  final spoken = await (phases == null ? speak() : phases.during('speaking the text', speak));
  script.deleteSync();
  if (!spoken.ok) throw GalleryError('say failed${voice == null ? '' : ' with voice "$voice"'}', spoken.errTail());
  final out = _generatedPath('$name.m4a');
  final encode = await _ffmpeg(['-y', '-hide_banner', '-loglevel', 'error', '-i', aiff, '-c:a', 'aac', '-b:a', '96k', out], phases, 'encoding speech');
  File(aiff).deleteSync();
  if (!encode.ok) throw GalleryError('ffmpeg could not encode the speech', encode.errTail());
  return File(out);
}

/// Renders a sine tone to `generated/<name>.m4a`.
Future<File> generateTone(num hz, num durationSec, String name, {PhaseReporter? phases}) async {
  final out = _generatedPath('$name.m4a');
  final run = await _ffmpeg(
      ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=$hz:duration=$durationSec:sample_rate=48000', '-c:a', 'aac', '-b:a', '96k', out],
      phases,
      'rendering the tone');
  if (!run.ok) throw GalleryError('ffmpeg could not render the tone', run.errTail());
  return File(out);
}
