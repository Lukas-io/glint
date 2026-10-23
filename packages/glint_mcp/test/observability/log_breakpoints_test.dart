import 'dart:async';

import 'package:glint_mcp/src/observability/app_log_buffer.dart';
import 'package:glint_mcp/src/observability/log_breakpoints.dart';
import 'package:test/test.dart';

AppLogEntry _line(int seq, String content, {AppLogStream stream = AppLogStream.logging}) =>
    AppLogEntry(sequence: seq, timestamp: DateTime(2026), stream: stream, content: content);

void main() {
  late StreamController<AppLogEntry> lines;
  late LogBreakpoints bps;
  late List<String> calls;
  String? pauseError;

  setUp(() {
    lines = StreamController<AppLogEntry>.broadcast(sync: true);
    calls = [];
    pauseError = null;
    bps = LogBreakpoints(
      pauseApp: () async {
        calls.add('pause');
        return pauseError;
      },
      resumeApp: () async {
        calls.add('resume');
        return null;
      },
      capture: () async {
        calls.add('capture');
        return '/tmp/shot.png';
      },
    )..listen(lines.stream);
  });

  tearDown(() => lines.close());

  test('a matching line pauses the app, screenshots it and becomes ready', () async {
    bps.add(RegExp(r'\[EventTracker\] vip_'));
    lines.add(_line(0, 'rqas: [EventTracker] login_started {}'));
    lines.add(_line(1, 'rqas: [EventTracker] vip_page_viewed {page: pitch}'));
    final hit = await bps.next(const Duration(seconds: 1));
    expect(hit, isNotNull);
    expect(hit!.matchedLine, contains('vip_page_viewed'));
    expect(hit.paused, isTrue);
    expect(hit.screenshotPath, '/tmp/shot.png');
    expect(calls, ['pause', 'capture']);
    expect(bps.isPaused, isTrue);
  });

  test('lines that match while paused are attached to the current hit, not paused again', () async {
    bps.add(RegExp('EventTracker'));
    lines.add(_line(0, '[EventTracker] a'));
    await bps.next(const Duration(seconds: 1));
    lines.add(_line(1, '[EventTracker] b'));
    expect(bps.pending, hasLength(1));
    expect(bps.pending.single.alsoMatched.single.content, '[EventTracker] b');
    expect(calls.where((c) => c == 'pause'), hasLength(1));
  });

  test('resume continues the app and consumes the hit', () async {
    bps.add(RegExp('x'));
    lines.add(_line(0, 'x'));
    await bps.next(const Duration(seconds: 1));
    final r = await bps.resume();
    expect(r.error, isNull);
    expect(r.hit!.number, 1);
    expect(bps.isPaused, isFalse);
    expect(bps.ready, isNull);
    expect(calls.last, 'resume');
  });

  test('once removes the breakpoint after its first hit', () async {
    bps.add(RegExp('x'), once: true);
    lines.add(_line(0, 'x'));
    expect(bps.armed, isEmpty);
  });

  test('pause:false records the hit without pausing', () async {
    bps.add(RegExp('x'), pause: false);
    lines.add(_line(0, 'x'));
    final hit = await bps.next(const Duration(seconds: 1));
    expect(hit!.paused, isFalse);
    expect(calls, isEmpty);
    expect(bps.isPaused, isFalse);
  });

  test('a stream filter ignores lines from other streams', () async {
    bps.add(RegExp('x'), stream: AppLogStream.stderr);
    lines.add(_line(0, 'x'));
    expect(bps.pending, isEmpty);
    lines.add(_line(1, 'x', stream: AppLogStream.stderr));
    expect(bps.pending, hasLength(1));
  });

  test('a failed pause is reported on the hit and does not leave the app marked paused', () async {
    pauseError = 'isolate gone';
    bps.add(RegExp('x'));
    lines.add(_line(0, 'x'));
    final hit = await bps.next(const Duration(seconds: 1));
    expect(hit!.paused, isFalse);
    expect(hit.pauseError, 'isolate gone');
    expect(bps.isPaused, isFalse);
  });

  test('wait times out with null when nothing matches', () async {
    bps.add(RegExp('never'));
    lines.add(_line(0, 'x'));
    expect(await bps.next(const Duration(milliseconds: 50)), isNull);
  });

  test('dispose resumes a paused app', () async {
    bps.add(RegExp('x'));
    lines.add(_line(0, 'x'));
    await bps.next(const Duration(seconds: 1));
    await bps.dispose();
    expect(calls.last, 'resume');
    expect(bps.isPaused, isFalse);
    expect(bps.armed, isEmpty);
  });
}
