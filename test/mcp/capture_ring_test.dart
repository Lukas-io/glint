import 'dart:io';

import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('glint-ring-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Capture shot(int i) {
    final f = File('${tmp.path}/$i.png')..writeAsStringSync('png');
    return Capture(
        path: f.path,
        takenAt: DateTime.now().subtract(Duration(seconds: 10 - i)),
        trigger: 'lifecycle',
        lifecycle: 'inactive',
        width: 10,
        height: 20);
  }

  test('keeps the newest ten and deletes evicted files', () {
    final ring = CaptureRing(max: 3);
    for (var i = 0; i < 5; i++) {
      ring.add(shot(i));
    }
    expect(ring.length, 3);
    expect(ring.newest!.path, endsWith('4.png'));
    expect(File('${tmp.path}/0.png').existsSync(), isFalse);
    expect(File('${tmp.path}/1.png').existsSync(), isFalse);
    expect(File('${tmp.path}/4.png').existsSync(), isTrue);
    ring.clear();
    expect(ring.length, 0);
    expect(File('${tmp.path}/4.png').existsSync(), isFalse);
  });

  test('describe and json carry size, age and trigger', () {
    final c = shot(3);
    expect(c.describe(), contains('10×20 px'));
    expect(c.describe(), contains('trigger lifecycle'));
    expect(c.toJson()['lifecycle'], 'inactive');
  });

  test('lifecycle classification', () {
    expect(describeLifecycle('inactive'), contains('over your app'));
    expect(describeLifecycle('paused'), contains('background'));
    expect(lifecycleIsOverlay('inactive'), isTrue);
    expect(lifecycleIsOverlay('paused'), isFalse);
  });
}
