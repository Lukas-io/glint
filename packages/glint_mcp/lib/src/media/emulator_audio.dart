import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../interaction/emulator_control.dart';

/// A speaker capture running in the background on one emulator, so the agent can act in the app meanwhile.
class EmulatorAudio {
  EmulatorAudio._(this.serial, this.control);

  final String serial;
  final EmulatorControl control;

  static final _bySerial = <String, EmulatorAudio>{};

  /// The audio state for [serial], reconnecting when the emulator restarted on a new port or token; null when it serves no gRPC endpoint.
  static EmulatorAudio? forSerial(String serial) {
    final endpoint = EmulatorEndpoint.find(serial);
    if (endpoint == null) return null;
    final existing = _bySerial[serial];
    final known = existing?.control.endpoint;
    if (existing != null && known!.port == endpoint.port && known.token == endpoint.token) return existing;
    return _bySerial[serial] = EmulatorAudio._(serial, EmulatorControl(endpoint));
  }

  StreamSubscription<List<int>>? _capture;
  final _captured = <({int ts, Uint8List audio})>[];
  DateTime? _captureStarted;

  /// Starts recording what the emulator plays.
  void startCapture() {
    _capture?.cancel();
    _captured.clear();
    _captureStarted = DateTime.now();
    _capture = control.streamAudio().listen((bytes) {
      final p = EmulatorControl.readPacket(bytes);
      if (p.audio.isNotEmpty) _captured.add((ts: p.timestampUs, audio: p.audio));
    }, onError: (_) {});
  }

  /// Stops the capture and lays every packet at its own time on a timeline from the start, so gaps read as silence.
  Future<({Uint8List pcm, Duration length})?> stopCapture() async {
    final sub = _capture;
    final started = _captureStarted;
    if (sub == null || started == null) return null;
    await sub.cancel();
    _capture = null;
    final length = DateTime.now().difference(started);
    final startUs = started.microsecondsSinceEpoch;
    final total = (length.inMicroseconds * sampleRate / 1e6).round();
    final samples = Int16List(total);
    for (final p in _captured) {
      final at = ((p.ts - startUs) * sampleRate / 1e6).round().clamp(0, total);
      final data = p.audio.buffer.asInt16List(p.audio.offsetInBytes, p.audio.lengthInBytes ~/ 2);
      for (var i = 0; i < data.length && at + i < total; i++) {
        samples[at + i] = data[i];
      }
    }
    return (pcm: samples.buffer.asUint8List(), length: length);
  }
}

/// Peak and RMS level in dBFS, and the stretches of at least [minSilence] quieter than [silenceDb].
({double peakDb, double rmsDb, List<(Duration, Duration)> silences}) audioStats(Uint8List pcm,
    {double silenceDb = -50, Duration minSilence = const Duration(milliseconds: 300)}) {
  final s = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 2);
  double db(double v) => v <= 0 ? -120 : 20 * log(v / 32768) / ln10;
  var peak = 0;
  var sum = 0.0;
  for (final v in s) {
    peak = max(peak, v.abs());
    sum += v * v.toDouble();
  }
  const window = sampleRate ~/ 20;
  final silences = <(Duration, Duration)>[];
  int? quietFrom;
  for (var w = 0; w * window < s.length; w++) {
    var e = 0.0;
    final end = min((w + 1) * window, s.length);
    for (var i = w * window; i < end; i++) {
      e += s[i] * s[i].toDouble();
    }
    final quiet = db(sqrt(e / max(1, end - w * window))) < silenceDb;
    if (quiet) quietFrom ??= w * window;
    if ((!quiet || end == s.length) && quietFrom != null) {
      final to = quiet ? end : w * window;
      if (to - quietFrom >= minSilence.inMicroseconds * sampleRate ~/ 1000000) {
        silences.add((
          Duration(microseconds: quietFrom * 1000000 ~/ sampleRate),
          Duration(microseconds: to * 1000000 ~/ sampleRate)
        ));
      }
      quietFrom = null;
    }
  }
  return (peakDb: db(peak.toDouble()), rmsDb: db(sqrt(sum / max(1, s.length))), silences: silences);
}

/// [pcm] as a mono 16-bit WAV file at [path].
File writeWav(String path, Uint8List pcm) {
  final h = ByteData(44);
  void tag(int at, String t) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, t.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return File(path)..writeAsBytesSync([...h.buffer.asUint8List(), ...pcm]);
}
