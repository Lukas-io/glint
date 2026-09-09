import 'dart:io';

/// One background screenshot and why it was taken.
class Capture {
  const Capture({
    required this.path,
    required this.takenAt,
    required this.trigger,
    this.lifecycle,
    this.width,
    this.height,
  });

  final String path;
  final DateTime takenAt;

  /// `lifecycle` (the app left resumed) or `explicit` (device op:screenshot).
  final String trigger;

  /// App lifecycle at capture time, when known.
  final String? lifecycle;
  final int? width;
  final int? height;

  Duration get age => DateTime.now().difference(takenAt);

  /// `1206×2622 px, 1.2s ago, trigger lifecycle`.
  String describe() => [
        if (width != null && height != null) '$width×$height px',
        '${(age.inMilliseconds / 1000).toStringAsFixed(1)}s ago',
        'trigger $trigger',
      ].join(', ');

  Map<String, Object?> toJson() => {
        'path': path,
        'takenAt': takenAt.toIso8601String(),
        'ageMs': age.inMilliseconds,
        'trigger': trigger,
        if (lifecycle != null) 'lifecycle': lifecycle,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };
}

/// The last [max] screenshots of one device, newest first. Evicting an entry
/// deletes its file; [clear] deletes them all. Never throws.
class CaptureRing {
  CaptureRing({this.max = 10});

  final int max;
  final List<Capture> _entries = [];

  List<Capture> get entries => List.unmodifiable(_entries);
  Capture? get newest => _entries.isEmpty ? null : _entries.first;
  int get length => _entries.length;

  void add(Capture c) {
    _entries.insert(0, c);
    while (_entries.length > max) {
      _delete(_entries.removeLast());
    }
  }

  void clear() {
    for (final c in _entries) {
      _delete(c);
    }
    _entries.clear();
  }

  void _delete(Capture c) {
    try {
      final f = File(c.path);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // best effort
    }
  }
}

/// What a non-resumed lifecycle means for the agent, in one line.
String describeLifecycle(String? lifecycle) => switch (lifecycle) {
      'inactive' =>
        'something is over your app (alert, permission prompt, sheet, control center)',
      'paused' || 'hidden' || 'detached' =>
        'your app is in the background (home screen or another app)',
      _ => 'your app is not in the foreground',
    };

/// True when the native layer is over the app rather than the app being away.
bool lifecycleIsOverlay(String? lifecycle) => lifecycle == 'inactive';
