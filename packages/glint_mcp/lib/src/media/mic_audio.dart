import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'gallery.dart';
import 'host_tools.dart';
import 'media_generate.dart';
import 'seed_ledger.dart';

/// The rate, channels and sample format the microphone feed takes: mono 16-bit little-endian at 48 kHz.
const micSampleRate = 48000;

/// A sine at [hz] for [seconds], as microphone PCM.
Uint8List tonePcm(double hz, {double seconds = 1, double level = 0.37}) {
  final n = (micSampleRate * seconds).round();
  final out = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    out.setInt16(i * 2, (sin(2 * pi * hz * i / micSampleRate) * 32767 * level).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Microphone PCM for [source] (tone, speech, or a host audio file), written to a host file, and a label for replies.
Future<({File pcm, String label})> micAudio(String source,
    {double? hz, String? text, String? voice, PhaseReporter? phases}) async {
  final out = File('${mediaDir('generated')}/mic-${DateTime.now().millisecondsSinceEpoch}.pcm');
  if (source == 'tone') {
    final f = hz ?? 1000;
    out.writeAsBytesSync(tonePcm(f));
    return (pcm: out, label: 'a ${f.toStringAsFixed(0)} Hz tone');
  }
  final File input;
  final String label;
  if (source == 'speech') {
    if (text == null || text.trim().isEmpty) throw GalleryError('mic source:speech needs text', '');
    input = await generateSpeech(text, 'mic-speech', voice: voice, phases: phases);
    label = 'speech "${text.length > 40 ? '${text.substring(0, 39)}…' : text}"';
  } else {
    input = File(source);
    if (!input.existsSync()) throw GalleryError('no audio file at $source', '');
    label = input.uri.pathSegments.last;
  }
  final r = await runHost(requireHostBinary('ffmpeg'), [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    input.path,
    '-f',
    's16le',
    '-ac',
    '1',
    '-ar',
    '$micSampleRate',
    out.path
  ]);
  if (r.exitCode != 0 || out.lengthSync() < 2) throw GalleryError('ffmpeg could not decode $label', r.errTail());
  return (pcm: out, label: label);
}
