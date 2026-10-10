import 'dart:convert';
import 'dart:io';

/// Another glint process driving a device.
class DeviceClaim {
  const DeviceClaim({required this.pid, required this.since, this.app});

  final int pid;
  final DateTime since;
  final String? app;

  String get describe => 'glint pid $pid${app == null ? '' : ' ($app)'} since ${since.toIso8601String().substring(11, 19)}';
}

/// One claim file per device under `~/.glint/claims`, so parallel agents never share a device by accident.
class DeviceClaims {
  DeviceClaims({String? dir, int? ownPid, bool Function(int pid)? isAlive})
      : dir = dir ?? '${Platform.environment['HOME'] ?? '.'}/.glint/claims',
        ownPid = ownPid ?? pid,
        _isAlive = isAlive ?? _pidAlive;

  final String dir;
  final int ownPid;
  final bool Function(int pid) _isAlive;

  File _file(String deviceId) => File('$dir/${deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json');

  /// Marks [deviceId] as driven by this process, unless another live session holds it (that claim stays theirs); best effort, since a claim only guards against accidents.
  void claim(String deviceId, {String? app}) {
    if (heldByOther(deviceId) != null) return;
    try {
      Directory(dir).createSync(recursive: true);
      _file(deviceId).writeAsStringSync(jsonEncode({
        'pid': ownPid,
        'since': DateTime.now().toIso8601String(),
        if (app != null) 'app': app,
      }));
    } on Object {
      // an unwritable home only loses the guard
    }
  }

  /// The live claim another process holds on [deviceId], or null when it is free or ours.
  DeviceClaim? heldByOther(String deviceId) {
    try {
      final j = jsonDecode(_file(deviceId).readAsStringSync()) as Map<String, Object?>;
      final holder = (j['pid'] as num).toInt();
      if (holder == ownPid || !_isAlive(holder)) return null;
      return DeviceClaim(
          pid: holder, since: DateTime.parse(j['since'] as String), app: j['app'] as String?);
    } on Object {
      return null;
    }
  }

  static bool _pidAlive(int pid) {
    try {
      return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
    } on Object {
      return false;
    }
  }
}
