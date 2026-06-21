import 'dart:io';

import 'package:glint/src/interaction/attach_history.dart';
import 'package:test/test.dart';

AttachRecord _rec(
  String appKey,
  String deviceId, {
  String? projectDir = '/proj/app',
  DateTime? at,
}) {
  final t = at ?? DateTime(2026, 6, 21, 12);
  return AttachRecord(
    appKey: appKey,
    deviceId: deviceId,
    platform: 'ios',
    deviceName: 'iPhone 17',
    projectDir: projectDir,
    firstSeen: t,
    lastSeen: t,
  );
}

void main() {
  late Directory tmp;
  late AttachHistory history;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('glint-hist-');
    history = AttachHistory(dataDir: tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('missing file → empty, no throw', () {
    expect(history.load(), isEmpty);
    expect(history.find(null), isNull);
  });

  test('corrupt file → empty, no throw', () {
    File('${tmp.path}/attach-history.json').writeAsStringSync('{not json');
    expect(history.load(), isEmpty);
  });

  test('record persists and round-trips', () {
    history.record(_rec('aetrust', 'udid-1'));
    final loaded = history.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.appKey, 'aetrust');
    expect(loaded.single.launchable, isTrue);
  });

  test('re-record same (app,device) bumps count, keeps firstSeen', () {
    final t1 = DateTime(2026, 6, 21, 10);
    final t2 = DateTime(2026, 6, 21, 12);
    history.record(_rec('aetrust', 'udid-1', at: t1));
    history.record(_rec('aetrust', 'udid-1', at: t2));
    final loaded = history.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.attachCount, 2);
    expect(loaded.single.firstSeen, t1);
    expect(loaded.single.lastSeen, t2);
  });

  test('same app on a different device is a separate record', () {
    history.record(_rec('aetrust', 'udid-1'));
    history.record(_rec('aetrust', 'udid-2'));
    expect(history.load(), hasLength(2));
  });

  test('most-recent-first ordering', () {
    history.record(_rec('old', 'd-old', at: DateTime(2026, 6, 20)));
    history.record(_rec('new', 'd-new', at: DateTime(2026, 6, 21)));
    expect(history.load().first.appKey, 'new');
  });

  test('caps at maxRecords, dropping the oldest', () {
    final h = AttachHistory(dataDir: tmp.path, maxRecords: 3);
    for (var i = 0; i < 5; i++) {
      h.record(_rec('app$i', 'd$i', at: DateTime(2026, 6, 21, i)));
    }
    final loaded = h.load();
    expect(loaded, hasLength(3));
    expect(loaded.map((r) => r.appKey), ['app4', 'app3', 'app2']);
  });

  test('find: null/true/last → most recent; appKey → exact; basename → path', () {
    history.record(_rec('aetrust', 'd1',
        projectDir: '/Users/x/StudioProjects/aetrust',
        at: DateTime(2026, 6, 21, 9)));
    history.record(_rec('sanga', 'd2',
        projectDir: '/Users/x/StudioProjects/sanga_mobile',
        at: DateTime(2026, 6, 21, 11)));
    expect(history.find(null)?.appKey, 'sanga');
    expect(history.find('true')?.appKey, 'sanga');
    expect(history.find('aetrust')?.appKey, 'aetrust');
    expect(history.find('sanga_mobile')?.appKey, 'sanga'); // projectDir basename
    expect(history.find('nope'), isNull);
  });

  test('record with no projectDir is not launchable', () {
    history.record(_rec('aetrust', 'd1', projectDir: null));
    expect(history.load().single.launchable, isFalse);
  });
}
