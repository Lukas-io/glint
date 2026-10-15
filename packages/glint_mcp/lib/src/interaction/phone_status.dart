import 'dart:convert';
import 'dart:io';

/// What `devicectl` reports about a paired iPhone: name, model, iOS, connection, developer readiness and passcode state; null when the phone does not answer.
Future<Map<String, Object?>?> phoneStatus(String udid) async {
  final tmp = await Directory.systemTemp.createTemp('glint-phone-');
  try {
    final details = '${tmp.path}/details.json';
    final lock = '${tmp.path}/lock.json';
    await Process.run('xcrun', ['devicectl', 'device', 'info', 'details', '--device', udid, '--json-output', details, '-q']);
    await Process.run('xcrun', ['devicectl', 'device', 'info', 'lockState', '--device', udid, '--json-output', lock, '-q']);
    final d = ((jsonDecode(File(details).readAsStringSync()) as Map)['result'] as Map?)?.cast<String, Object?>();
    if (d == null) return null;
    Map<String, Object?> part(String key) => (d[key] as Map?)?.cast<String, Object?>() ?? const {};
    final dp = part('deviceProperties');
    final hp = part('hardwareProperties');
    final cp = part('connectionProperties');
    Map<String, Object?>? l;
    try {
      l = ((jsonDecode(File(lock).readAsStringSync()) as Map)['result'] as Map?)?.cast<String, Object?>();
    } on Object {
      l = null;
    }
    return {
      'name': dp['name'],
      'model': hp['marketingName'],
      'os': 'iOS ${dp['osVersionNumber']}',
      'build': dp['osBuildUpdate'],
      'developerMode': dp['developerModeStatus'],
      'developerImage': dp['ddiServicesAvailable'],
      'connection': cp['transportType'],
      'tunnel': cp['tunnelState'],
      if (l != null) 'passcodeRequired': l['passcodeRequired'],
      if (l != null) 'unlockedSinceBoot': l['unlockedSinceBoot'],
    };
  } on Object {
    return null;
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// How the iPhone reaches this Mac (`wired` or `localNetwork`), from `devicectl`; null when it does not answer.
Future<String?> phoneTransport(String udid) async {
  final tmp = await Directory.systemTemp.createTemp('glint-phone-');
  try {
    final details = '${tmp.path}/details.json';
    await Process.run('xcrun', ['devicectl', 'device', 'info', 'details', '--device', udid, '--json-output', details, '-q']);
    final d = (jsonDecode(File(details).readAsStringSync()) as Map)['result'] as Map?;
    return (d?['connectionProperties'] as Map?)?['transportType'] as String?;
  } on Object {
    return null;
  } finally {
    await tmp.delete(recursive: true);
  }
}
