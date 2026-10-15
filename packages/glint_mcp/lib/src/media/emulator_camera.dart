import 'dart:convert';
import 'dart:io';

import '../interaction/emulator_control.dart';
import 'host_tools.dart';
import 'seed_ledger.dart';

/// The two emulator cameras; both show the one environment glint sets.
const cameraNames = {'back', 'front'};

/// The emulator's camera frame is 4:3 landscape, and an app sees only its left 3:4 part at full height, so a feed is fitted into that part.
const _frameW = 1280, _frameH = 960, _visibleW = 720;

/// glint's live feed for an Android emulator's cameras: the AVD's cameras run in `environment` mode once, then glint swaps the image or video at runtime through `setEnvironment`.
class EmulatorCamera {
  EmulatorCamera({required this.avdDir, required this.avdName, String? home})
      : _home = home ?? Platform.environment['HOME'] ?? '';

  final String avdDir;
  final String avdName;
  final String _home;

  File get _config => File('$avdDir/config.ini');
  File get _running => File('$avdDir/hardware-qemu.ini');
  File get _environment => File('$avdDir/environment.ini');
  File get _saved => File('${mediaDir('camera')}/$avdName-original.json');
  File get _features => File('$_home/.android/advancedFeatures.ini');
  String get _idle => '${mediaDir('camera')}/$avdName-idle.png';

  /// Whether `config.ini` puts [camera] in environment mode.
  bool configured(String camera) => _read(_config, 'hw.camera.$camera') == 'environment';

  /// Whether the running emulator started with [camera] in environment mode (it reads `config.ini` only at launch).
  bool live(String camera) => _read(_running, 'hw.camera.$camera') == 'environment';

  /// Puts both cameras in environment mode, starting on a grey frame, and turns on video playback; keeps the old values for [undo].
  Future<void> setup() async {
    final ffmpeg = requireHostBinary('ffmpeg');
    if (!_saved.existsSync()) {
      _saved.writeAsStringSync(jsonEncode({
        for (final c in cameraNames) c: _read(_config, 'hw.camera.$c'),
        'environmentIni': _environment.existsSync() ? _environment.readAsStringSync() : null,
        'addedVideoPlayback': !_videoPlaybackOn(),
      }));
    }
    final idle = await runHost(ffmpeg,
        ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=${_frameW}x$_frameH', '-frames:v', '1', _idle]);
    if (!idle.ok) throw StateError('ffmpeg could not make the idle camera frame: ${idle.errTail()}');
    for (final c in cameraNames) {
      _write(_config, 'hw.camera.$c', 'environment');
    }
    _environment.writeAsStringSync('version=1\nscene.mode = imagefile:$_idle\n');
    if (!_videoPlaybackOn()) {
      _features.parent.createSync(recursive: true);
      _features.writeAsStringSync('${_features.existsSync() ? _features.readAsStringSync() : ''}VideoPlayback = on\n');
    }
  }

  /// Restores the cameras, `environment.ini` and the video playback setting from before [setup], and drops glint's feed files; false when there was nothing to undo.
  bool undo() {
    if (!_saved.existsSync()) return false;
    final saved = jsonDecode(_saved.readAsStringSync()) as Map<String, Object?>;
    for (final c in cameraNames) {
      final old = saved[c] as String?;
      if (old != null) _write(_config, 'hw.camera.$c', old);
    }
    final ini = saved['environmentIni'] as String?;
    if (ini != null) {
      _environment.writeAsStringSync(ini);
    } else if (_environment.existsSync()) {
      _environment.deleteSync();
    }
    if (saved['addedVideoPlayback'] == true && _features.existsSync()) {
      final kept = _features
          .readAsLinesSync()
          .where((l) => l.replaceAll(' ', '').toLowerCase() != 'videoplayback=on')
          .join('\n');
      kept.trim().isEmpty ? _features.deleteSync() : _features.writeAsStringSync('$kept\n');
    }
    _saved.deleteSync();
    for (final f in Directory(mediaDir('camera')).listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.startsWith('$avdName-feed-') || name == '$avdName-idle.png') f.deleteSync();
    }
    return true;
  }

  bool _videoPlaybackOn() =>
      _features.existsSync() &&
      _features.readAsLinesSync().any((l) => l.replaceAll(' ', '').toLowerCase() == 'videoplayback=on');

  /// Shows [source] (an image or a video) in both cameras now, fitted whole into what an app sees, through [control].
  Future<String> feed(File source, EmulatorControl control) async {
    final ffmpeg = requireHostBinary('ffmpeg');
    final video = !RegExp(r'\.(png|jpe?g|webp|heic|bmp|gif)$', caseSensitive: false).hasMatch(source.path);
    for (final old
        in Directory(mediaDir('camera')).listSync().whereType<File>().where((f) => f.path.contains('$avdName-feed-'))) {
      old.deleteSync();
    }
    final out = '${mediaDir('camera')}/$avdName-feed-${DateTime.now().millisecondsSinceEpoch}.${video ? 'mp4' : 'png'}';
    final fit = 'scale=$_visibleW:$_frameH:force_original_aspect_ratio=decrease,'
        'pad=$_visibleW:$_frameH:(ow-iw)/2:(oh-ih)/2:black,pad=$_frameW:$_frameH:0:0:black';
    final run = await runHost(ffmpeg, [
      '-y',
      '-v',
      'error',
      '-i',
      source.path,
      '-vf',
      fit,
      if (video) ...['-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p'] else ...['-frames:v', '1'],
      out,
    ]);
    if (!run.ok) throw StateError('ffmpeg could not fit ${source.path} for the camera: ${run.errTail()}');
    await control.setEnvironment({'version': '1', 'scene.mode': '${video ? 'videofile' : 'imagefile'}:$out'});
    return out;
  }

  static String? _read(File f, String key) {
    if (!f.existsSync()) return null;
    for (final line in f.readAsLinesSync()) {
      final i = line.indexOf('=');
      if (i > 0 && line.substring(0, i).trim() == key) return line.substring(i + 1).trim();
    }
    return null;
  }

  static void _write(File f, String key, String value) {
    final lines = f.existsSync() ? f.readAsLinesSync() : <String>[];
    final i = lines.indexWhere((l) => l.contains('=') && l.substring(0, l.indexOf('=')).trim() == key);
    if (i >= 0) {
      lines[i] = '$key=$value';
    } else {
      lines.add('$key=$value');
    }
    f.writeAsStringSync('${lines.join('\n')}\n');
  }
}
