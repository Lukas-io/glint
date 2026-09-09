import 'dart:io';

import 'package:glint/src/interaction/screen_recording.dart';
import 'package:glint/src/mcp/frame_sampling.dart';
import 'package:test/test.dart';

void main() {
  group('parseFrameLines', () {
    test('reads frame lines and the done summary, skipping noise', () {
      const out = '''
[warmup] ignore me
{"path":"/a/frame-00000ms.png","atMs":0}
not json
{"path":"/a/frame-00210ms.png","atMs":210}
{"done":true,"durationMs":1234,"sampled":25,"emitted":2,"capped":false}
''';
      final p = parseFrameLines(out);
      expect(p.frames.map((f) => f.atMs), [0, 210]);
      expect(p.durationMs, 1234);
      expect(p.sampled, 25);
      expect(p.capped, isFalse);
    });

    test('empty output yields no frames', () {
      final p = parseFrameLines('');
      expect(p.frames, isEmpty);
      expect(p.durationMs, isNull);
    });
  });

  group('withHoldMs', () {
    test('each frame holds until the next; the last until endMs', () {
      final frames = <SampledFrame>[
        (path: 'a', atMs: 0),
        (path: 'b', atMs: 210),
        (path: 'c', atMs: 540),
      ];
      final held = withHoldMs(frames, endMs: 1200);
      expect(held.map((f) => f.holdMs), [210, 330, 660]);
      expect(held.map((f) => f.index), [1, 2, 3]);
    });

    test('a single frame holds for the whole wall time', () {
      final held = withHoldMs([(path: 'a', atMs: 0)], endMs: 900);
      expect(held.single.holdMs, 900);
    });

    test('no frames yields nothing', () {
      expect(withHoldMs(const [], endMs: 900), isEmpty);
    });
  });

  group('describeFrames', () {
    test('names count, time and each frame', () {
      final held = withHoldMs(
          [(path: 'a', atMs: 0), (path: 'b', atMs: 500)], endMs: 1000);
      final s = describeFrames(held, 1000, distinctOnly: true);
      expect(s, contains('2 distinct frames over 1.0 s'));
      expect(s, contains('#1 0 ms (held 500 ms)'));
      expect(s, contains('#2 500 ms (held 500 ms)'));
    });

    test('empty is stated', () {
      expect(describeFrames(const [], 800, distinctOnly: true),
          contains('no frames'));
    });
  });

  group('FrameExtractor', () {
    test('uses the bridge when present and parses its output', () async {
      final bridge = File('${Directory.systemTemp.path}/fake-bridge-${DateTime.now().microsecondsSinceEpoch}')
        ..writeAsStringSync('x');
      addTearDown(() => bridge.deleteSync());
      List<String>? seen;
      final ex = FrameExtractor(
        bridgePath: bridge.path,
        run: (exe, args) async {
          seen = [exe, ...args];
          return ProcessResult(0, 0,
              '{"path":"/f/frame-00000ms.png","atMs":0}\n{"done":true,"durationMs":900,"sampled":9,"emitted":1,"capped":false}',
              '');
        },
      );
      final r = await ex.extract(
          video: '/v.mp4', outDir: '/out', everyMs: 50, maxFrames: 12, distinctOnly: true);
      expect(r.tool, 'bridge');
      expect(r.frames.single.atMs, 0);
      expect(r.durationMs, 900);
      expect(seen, ['${bridge.path}', 'frames', '/v.mp4', '/out', '50', '12', '1']);
    });

    test('no bridge and no ffmpeg leaves an error and the video', () async {
      final ex = FrameExtractor(
        bridgePath: '/does/not/exist',
        ffmpegPath: 'definitely-not-ffmpeg-xyz',
        run: (exe, args) async => throw const ProcessException('x', []),
      );
      final r = await ex.extract(
          video: '/v.mp4', outDir: '${Directory.systemTemp.path}/o', everyMs: 50, maxFrames: 12, distinctOnly: true);
      expect(r.frames, isEmpty);
      expect(r.error, isNotNull);
    });
  });

  group('AdbRecording argv', () {
    test('start, exists, stop, pull, remove', () {
      expect(AdbRecording.startArgs('emu-1'),
          ['-s', 'emu-1', 'shell', 'screenrecord', '--time-limit', '30', '/sdcard/glint-rec.mp4']);
      expect(AdbRecording.existsArgs('emu-1'),
          ['-s', 'emu-1', 'shell', 'ls', '/sdcard/glint-rec.mp4']);
      expect(AdbRecording.stopArgs('emu-1'),
          ['-s', 'emu-1', 'shell', 'pkill', '-l', 'INT', 'screenrecord']);
      expect(AdbRecording.pullArgs('emu-1', '/tmp/v.mp4'),
          ['-s', 'emu-1', 'pull', '/sdcard/glint-rec.mp4', '/tmp/v.mp4']);
      expect(AdbRecording.removeArgs('emu-1'),
          ['-s', 'emu-1', 'shell', 'rm', '-f', '/sdcard/glint-rec.mp4']);
    });
  });
}
