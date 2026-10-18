import 'dart:io';

/// A Mac camera the Android emulator can pass through, as `-webcam-list` names it.
typedef Webcam = ({String id, String name});

/// The Mac cameras the emulator at [emulatorPath] sees.
Future<List<Webcam>> listWebcams(String emulatorPath) async {
  try {
    final r = await Process.run(emulatorPath, ['-webcam-list']).timeout(const Duration(seconds: 20));
    return [
      for (final m in RegExp(r"Camera '(webcam\d+)' is connected to device '([^']*)'").allMatches('${r.stdout}'))
        (id: m.group(1)!, name: m.group(2)!),
    ];
  } on Object {
    return const [];
  }
}

/// The Mac's own camera from [cams]: a built-in FaceTime camera first, never a Continuity Camera phone or Desk View when anything else exists.
Webcam? builtInWebcam(List<Webcam> cams) {
  bool builtIn(Webcam c) => RegExp('facetime|built-in|macbook', caseSensitive: false).hasMatch(c.name);
  bool borrowed(Webcam c) => RegExp('iphone|ipad|continuity|desk view', caseSensitive: false).hasMatch(c.name);
  return cams.where(builtIn).firstOrNull ?? cams.where((c) => !borrowed(c)).firstOrNull;
}

/// True when the emulator behind [serial] keeps logging that its camera got no frame: at least three times in [within], the last in the past 6 s. macOS has not let it use the Mac's camera; one or two at camera start are a warm-up.
Future<bool> emulatorCameraStarved(String adbPath, String serial,
    {Duration within = const Duration(seconds: 20)}) async {
  try {
    final now = await Process.run(adbPath, ['-s', serial, 'shell', 'date', '+%s']).timeout(const Duration(seconds: 5));
    final deviceNow = int.tryParse('${now.stdout}'.trim());
    if (deviceNow == null) return false;
    final log = await Process.run(adbPath, ['-s', serial, 'logcat', '-d', '-v', 'epoch', '-t', '400'])
        .timeout(const Duration(seconds: 5));
    final ages = [
      for (final line in '${log.stdout}'.split('\n'))
        if (line.contains('Unable to obtain video frame'))
          if (double.tryParse(line.trim().split(RegExp(r'\s+')).first) case final at?) deviceNow - at,
    ].where((age) => age <= within.inSeconds).toList();
    return ages.length >= 3 && ages.reduce((a, b) => a < b ? a : b) <= 6;
  } on Object {
    return false;
  }
}

/// What an agent tells the user when [emulatorCameraStarved] is true.
const emulatorCameraStarvedWarning =
    'the emulator camera is getting no frames (logcat: "Unable to obtain video frame"), so its preview is blank: '
    'macOS has not let the emulator use the Mac camera. This is not an app bug. Ask the user to allow the emulator '
    '(qemu-system) in System Settings, Privacy & Security, Camera, then restart the emulator; or boot it without '
    'camera:"webcam" to use its virtual scene camera';
