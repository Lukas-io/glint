/// Standard gravity in m/s².
const double gravity = 9.81;

/// The accelerometer reading of a device at rest in each orientation (Android axes: x right, y up the screen, z out of it).
const Map<String, List<double>> restingAcceleration = {
  'portrait': [0, gravity, 0],
  'portraitUpsideDown': [0, -gravity, 0],
  'landscapeLeft': [gravity, 0, 0],
  'landscapeRight': [-gravity, 0, 0],
  'faceUp': [0, 0, gravity],
  'faceDown': [0, 0, -gravity],
};

/// The orientation whose resting reading [a] is closest to, named as iOS names device orientations; null when the device is moving or tilted between two.
String? orientationFromAcceleration(List<double> a) {
  if (a.length < 3) return null;
  final i = [0, 1, 2].reduce((best, k) => a[k].abs() > a[best].abs() ? k : best);
  if (a[i].abs() < gravity * 0.75) return null;
  return switch ((i, a[i] > 0)) {
    (0, true) => 'landscapeLeft',
    (0, false) => 'landscapeRight',
    (1, true) => 'portrait',
    (1, false) => 'portraitUpsideDown',
    (2, true) => 'faceUp',
    _ => 'faceDown',
  };
}

/// One sensor's newest sample from `dumpsys sensorservice`.
typedef SensorSample = ({List<double> values, String? wall});

/// The newest accelerometer, gyroscope, magnetic field and rotation vector samples in a `dumpsys sensorservice` dump; a sensor nothing is listening to has none.
Map<String, SensorSample> parseSensorService(String dump) {
  final out = <String, SensorSample>{};
  String? current;
  SensorSample? last;
  void flush() {
    final c = current, l = last;
    if (c != null && l != null) out.putIfAbsent(c, () => l);
    current = null;
    last = null;
  }

  final header = RegExp(r'^(.+): last \d+ events\s*$');
  final event = RegExp(r'^\s*\d+ \(ts=[\d.]+, wall=([\d:.]+)\) ([-\d., ]+)$');
  for (final line in dump.split('\n')) {
    final h = header.firstMatch(line);
    if (h != null) {
      flush();
      current = _kind(h.group(1)!);
      continue;
    }
    if (current == null) continue;
    final e = event.firstMatch(line);
    if (e == null) {
      if (line.trim().isEmpty || !line.startsWith('\t')) flush();
      continue;
    }
    final values = [
      for (final v in e.group(2)!.split(','))
        if (v.trim().isNotEmpty) double.tryParse(v.trim()) ?? 0
    ];
    last = (values: values, wall: e.group(1));
  }
  flush();
  return out;
}

String? _kind(String name) {
  final n = name.toLowerCase();
  if (n.contains('uncalibrated')) return null;
  if (n.contains('accelerometer')) return 'accelerometer';
  if (n.contains('gyroscope')) return 'gyroscope';
  if (n.contains('magnetic')) return 'magneticField';
  if (n.contains('game rotation')) return null;
  if (n.contains('rotation vector')) return 'rotationVector';
  return null;
}

/// The display rotation in quarter turns from `dumpsys window displays`, or null.
int? displayRotation(String dump) {
  final m = RegExp(r'^\s*mRotation=(\d)', multiLine: true).firstMatch(dump);
  return m == null ? null : int.parse(m.group(1)!);
}

/// What a display rotation means for the interface, in the same words as device orientations.
String interfaceOrientationFor(int rotation) => switch (rotation) {
      1 => 'landscapeLeft',
      2 => 'portraitUpsideDown',
      3 => 'landscapeRight',
      _ => 'portrait',
    };
