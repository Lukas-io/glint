import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() => runApp(const MediaFixtureApp());

class MediaFixtureApp extends StatelessWidget {
  const MediaFixtureApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Media Fixture',
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        home: const MediaPage(),
      );
}

class MediaPage extends StatefulWidget {
  const MediaPage({super.key});

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  String? _path;
  String _status = 'Idle';
  double _loudest = -160;

  Future<void> _record() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _status = 'Microphone permission denied');
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/voice_note.m4a';
    _loudest = -160;
    setState(() => _status = 'Recording');
    await _recorder.start(const RecordConfig(), path: path);
    final sub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) => _loudest = max(_loudest, a.current));
    await Future<void>.delayed(const Duration(seconds: 3));
    await sub.cancel();
    _path = await _recorder.stop();
    setState(() => _status = 'Recorded, loudest ${_loudest.toStringAsFixed(0)} dB');
  }

  Future<void> _playRecording() async {
    final path = _path;
    if (path == null) return;
    setState(() => _status = 'Playing recording');
    await _player.play(DeviceFileSource(path));
  }

  Future<void> _playBeep() async {
    setState(() => _status = 'Playing beep');
    await _player.play(AssetSource('beep.wav'));
  }

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Media Fixture')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Text(_status),
              FilledButton(onPressed: _record, child: const Text('Record 3 s')),
              OutlinedButton(onPressed: _path == null ? null : _playRecording, child: const Text('Play recording')),
              OutlinedButton(onPressed: _playBeep, child: const Text('Play beep')),
              const SizedBox(height: 16),
              const _ZoomArea(),
            ],
          ),
        ),
      );
}

/// A pinch target: the zoom it reads back is how glint checks a pinch landed.
class _ZoomArea extends StatefulWidget {
  const _ZoomArea();

  @override
  State<_ZoomArea> createState() => _ZoomAreaState();
}

class _ZoomAreaState extends State<_ZoomArea> {
  final _zoom = TransformationController();

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text('zoom ${_zoom.value.getMaxScaleOnAxis().toStringAsFixed(1)}x'),
          SizedBox(
            width: 240,
            height: 160,
            child: InteractiveViewer(
              transformationController: _zoom,
              minScale: 0.5,
              maxScale: 4,
              child: Semantics(
                label: 'Zoom area',
                child: Container(color: Colors.teal, alignment: Alignment.center, child: const Text('Pinch me')),
              ),
            ),
          ),
        ],
      );
}
