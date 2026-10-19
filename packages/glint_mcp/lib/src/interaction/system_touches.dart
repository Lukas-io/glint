import 'dart:convert';
import 'dart:io';

import 'emulator_control.dart';
import 'touch_path.dart';

/// Real touches through an Android emulator's own virtual touchscreen, which Android's `show_touches` draws everywhere: in the app, over permission dialogs and the shade, and in screen recordings.
class EmulatorTouches {
  EmulatorTouches(this.control);

  final EmulatorControl control;
  int _nextId = 1;

  /// How hard a finger presses; any value above 0 counts as down.
  static const _pressure = 100;

  Future<void> tap(int x, int y) => _play([(x: x, y: y, ms: 0), (x: x, y: y, ms: 60)]);

  Future<void> longPress(int x, int y, int durationMs) => _play([(x: x, y: y, ms: 0), (x: x, y: y, ms: durationMs)]);

  Future<void> swipe(int x1, int y1, int x2, int y2, {required int durationMs, int holdMs = 0}) =>
      _play(dragPath(x1, y1, x2, y2, durationMs: durationMs, holdMs: holdMs));

  /// Two fingers on a horizontal line through ([cx], [cy]), moving from [from] to [to] pixels apart over [durationMs].
  Future<void> pinch(int cx, int cy, {required int from, required int to, required int durationMs}) async {
    final a = _nextId++, b = _nextId++;
    final steps = (durationMs / 16).ceil().clamp(2, 400);
    final clock = Stopwatch()..start();
    ({int id, int x, int y, int pressure}) finger(int id, int span, int side, int pressure) =>
        (id: id, x: cx + side * span ~/ 2, y: cy, pressure: pressure);
    var span = from;
    for (var i = 0; i <= steps; i++) {
      span = (from + (to - from) * i / steps).round();
      await _waitUntil(clock, (durationMs * i / steps).round());
      await control.sendTouch([finger(a, span, -1, _pressure), finger(b, span, 1, _pressure)]);
    }
    await control.sendTouch([finger(a, span, -1, 0), finger(b, span, 1, 0)]);
  }

  Future<void> _play(List<TouchPoint> path) async {
    final id = _nextId++;
    final clock = Stopwatch()..start();
    for (final p in path) {
      await _waitUntil(clock, p.ms);
      await control.sendTouch([(id: id, x: p.x, y: p.y, pressure: _pressure)]);
    }
    await control.sendTouch([(id: id, x: path.last.x, y: path.last.y, pressure: 0)]);
  }

  static Future<void> _waitUntil(Stopwatch clock, int ms) async {
    final wait = ms - clock.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }

  Future<void> close() => control.close();
}

/// Android's `show_touches` developer setting on one device, switched on for glint and put back as it was; the old value waits in `~/.glint/touches` so even a crashed glint restores it at the next attach.
class ShowTouchesSetting {
  ShowTouchesSetting({required this.adbPath, required this.serial, Map<String, String>? env})
      : _home = (env ?? Platform.environment)['HOME'] ?? '.';

  final String adbPath;
  final String serial;
  final String _home;

  File get _saved => File('$_home/.glint/touches/$serial.json');

  /// Whether glint switched it on and has not put it back yet.
  bool get pending => _saved.existsSync();

  /// Switches it on, remembering the value it had unless an earlier switch-on is still unrestored.
  Future<void> enable() async {
    if (!pending) {
      final prior = await _settings(['get', 'system', 'show_touches']);
      _saved
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'prior': prior}));
    }
    await _settings(['put', 'system', 'show_touches', '1']);
  }

  /// Puts back the value it had before glint switched it on; nothing when glint did not.
  Future<void> restore() async {
    if (!pending) return;
    String? prior;
    try {
      prior = (jsonDecode(_saved.readAsStringSync()) as Map<String, Object?>)['prior'] as String?;
    } on Object {
      prior = null;
    }
    if (prior == null || prior.isEmpty || prior == 'null') {
      await _settings(['delete', 'system', 'show_touches']);
    } else {
      await _settings(['put', 'system', 'show_touches', prior]);
    }
    _saved.deleteSync();
  }

  Future<String> _settings(List<String> args) async {
    final r =
        await Process.run(adbPath, ['-s', serial, 'shell', 'settings', ...args]).timeout(const Duration(seconds: 10));
    if (r.exitCode != 0) throw ProcessException(adbPath, args, '${r.stderr}'.trim(), r.exitCode);
    return '${r.stdout}'.trim();
  }
}
