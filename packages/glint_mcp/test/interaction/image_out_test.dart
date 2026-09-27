import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:glint_mcp/observability.dart';
import 'package:test/test.dart';

void main() {
  group('modelImageSize', () {
    test('caps the longest side and keeps the aspect ratio', () {
      expect(modelImageSize(1206, 2622, 1024), (width: 471, height: 1024));
      expect(modelImageSize(2400, 1080, 1024), (width: 1024, height: 461));
    });

    test('never upscales, and 0 means full size', () {
      expect(modelImageSize(400, 800, 1024), (width: 400, height: 800));
      expect(modelImageSize(1206, 2622, 0), (width: 1206, height: 2622));
    });
  });

  group('prepareModelImage', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('glint-image-out'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('asks the resizer for a capped JPEG and reports its size and type', () async {
      final src = '${dir.path}/shot.png';
      File(src).writeAsBytesSync([0]);
      late List<String> args;
      final out = await prepareModelImage(src,
          width: 1206,
          height: 2622,
          maxSize: 1024,
          format: 'jpeg',
          quality: 75, run: (_, a) async {
        args = a;
        File(a.last).writeAsBytesSync([0]);
        return ProcessResult(0, 0, '', '');
      });
      expect(out.mimeType, 'image/jpeg');
      expect((out.width, out.height), (471, 1024));
      expect(out.path, endsWith('shot-model.jpg'));
      expect(args, containsAllInOrder(Platform.isMacOS ? ['-Z', '1024'] : ['-resize', '1024x1024']));
      expect(args, contains('75'));
    });

    test('falls back to the original PNG when the resizer fails', () async {
      final src = '${dir.path}/shot.png';
      final out = await prepareModelImage(src,
          width: 1206,
          height: 2622,
          maxSize: 1024,
          format: 'jpeg',
          quality: 75,
          run: (_, __) async => ProcessResult(0, 1, '', 'no resizer'));
      expect(out, (path: src, width: 1206, height: 2622, mimeType: 'image/png'));
    });

    test('a small PNG that needs no change is sent as it is', () async {
      final src = '${dir.path}/small.png';
      var ran = false;
      final out = await prepareModelImage(src,
          width: 400, height: 800, maxSize: 1024, format: 'png', quality: 75,
          run: (_, __) async {
        ran = true;
        return ProcessResult(0, 0, '', '');
      });
      expect(ran, isFalse);
      expect(out.path, src);
    });
  });

  group('screenshot config', () {
    test('defaults to a 1024 px JPEG at quality 75', () {
      final c = GlintConfig();
      expect((c.screenshotMaxSize, c.screenshotFormat, c.screenshotQuality), (1024, 'jpeg', 75));
    });

    test('validates each key', () {
      final c = GlintConfig();
      expect(c.set('screenshotMaxSize', 0), isNull);
      expect(c.set('screenshotMaxSize', -1), isNotNull);
      expect(c.set('screenshotFormat', 'PNG'), isNull);
      expect(c.screenshotFormat, 'png');
      expect(c.set('screenshotFormat', 'webp'), isNotNull);
      expect(c.set('screenshotQuality', 101), isNotNull);
      expect(c.set('screenshotQuality', '60'), isNull);
      expect(c.screenshotQuality, 60);
    });
  });
}
