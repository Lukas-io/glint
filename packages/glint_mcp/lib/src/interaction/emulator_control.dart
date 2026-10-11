import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

/// The gRPC endpoint every running Android emulator serves, read from its `pid_<n>.ini` in the AVD running directory.
class EmulatorEndpoint {
  const EmulatorEndpoint({required this.port, required this.token, this.avdDir, this.avdName});
  final int port;
  final String token;

  /// The AVD folder and name of that emulator, from the same file.
  final String? avdDir;
  final String? avdName;

  /// The endpoint of the emulator behind adb [serial] (`emulator-5554`), or null when none is running or it serves no gRPC.
  static EmulatorEndpoint? find(String serial, {Map<String, String>? env}) {
    final record = runningRecord(serial, env: env);
    return record == null ? null : fromRecord(record);
  }

  /// The running record (`pid_<n>.ini`) of the emulator behind [serial], parsed, or null when it wrote none where glint looks.
  static Map<String, String>? runningRecord(String serial, {Map<String, String>? env}) {
    final consolePort = RegExp(r'^emulator-(\d+)$').firstMatch(serial)?.group(1);
    if (consolePort == null) return null;
    final e = env ?? Platform.environment;
    final home = e['HOME'] ?? '';
    final dirs = [
      '$home/Library/Caches/TemporaryItems/avd/running',
      if (e['XDG_RUNTIME_DIR'] != null) '${e['XDG_RUNTIME_DIR']}/avd/running',
      '/tmp/android-${e['USER'] ?? ''}/avd/running',
      '$home/.android/avd/running',
    ];
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.ini'))) {
        final ini = parseIni(f.readAsStringSync());
        if (ini['port.serial'] == consolePort) return ini;
      }
    }
    return null;
  }

  static EmulatorEndpoint? fromRecord(Map<String, String> ini) {
    final port = int.tryParse(ini['grpc.port'] ?? '');
    if (port == null) return null;
    return EmulatorEndpoint(port: port, token: ini['grpc.token'] ?? '', avdDir: ini['avd.dir'], avdName: ini['avd.id']);
  }

  static Map<String, String> parseIni(String text) => {
        for (final line in text.split('\n'))
          if (line.contains('=')) line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
      };
}

/// Runs one emulator console command through `adb emu` and returns its answer lines without the closing OK; null when the console refuses or adb fails.
Future<List<String>?> emulatorConsole(String adbPath, String serial, List<String> command) async {
  try {
    final r = await Process.run(adbPath, ['-s', serial, 'emu', ...command]).timeout(const Duration(seconds: 10));
    final lines = '${r.stdout}'.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (r.exitCode != 0 || lines.isEmpty || lines.last != 'OK') return null;
    return lines.sublist(0, lines.length - 1);
  } on Object {
    return null;
  }
}

/// One running emulator: its AVD, and its gRPC control when it serves one.
class EmulatorInstance {
  const EmulatorInstance({required this.serial, this.avdName, this.avdDir, this.grpc});

  final String serial;
  final String? avdName;
  final String? avdDir;
  final EmulatorEndpoint? grpc;

  /// Finds [serial]'s AVD from its running record, else from its console, which answers even when a sandboxed launch could not write the record.
  static Future<EmulatorInstance?> locate(String serial, {required String adbPath}) async {
    if (!serial.startsWith('emulator-')) return null;
    var record = EmulatorEndpoint.runningRecord(serial);
    if (record == null) {
      final elsewhere = (await emulatorConsole(adbPath, serial, ['avd', 'discoverypath']))?.firstOrNull;
      final file = elsewhere == null ? null : File(elsewhere);
      if (file != null && file.existsSync()) record = EmulatorEndpoint.parseIni(file.readAsStringSync());
    }
    if (record != null) {
      return EmulatorInstance(
        serial: serial,
        avdName: record['avd.id'],
        avdDir: record['avd.dir'],
        grpc: EmulatorEndpoint.fromRecord(record),
      );
    }
    final name = (await emulatorConsole(adbPath, serial, ['avd', 'name']))?.firstOrNull;
    final dir = (await emulatorConsole(adbPath, serial, ['avd', 'path']))?.firstOrNull;
    if (name == null && dir == null) return null;
    return EmulatorInstance(serial: serial, avdName: name, avdDir: dir);
  }

  String get label => avdName == null ? serial : '$serial ($avdName)';

  /// Why this emulator has no gRPC control, for replies whose feature needs it.
  String get noControlReason => '$label runs without its gRPC control and wrote no running record: '
      'the emulator does not always start gRPC on its own, and cannot when launched from a sandboxed shell';

  /// How to get an emulator of the same AVD with its control on.
  List<String> get controlSteps => [
        'close it (`shutdown_sim device:"$serial"` if this session started it)',
        if (avdName != null) 'then `attach device:"$avdName"`: glint boots the AVD from its own process, with gRPC on',
      ];
}

/// Mono signed 16-bit little-endian PCM at [sampleRate], the one format glint feeds and captures.
const sampleRate = 48000;

/// The emulator's controller service over gRPC, with the few messages glint needs encoded by hand.
class EmulatorControl {
  EmulatorControl(this.endpoint)
      : _channel = ClientChannel('127.0.0.1',
            port: endpoint.port, options: const ChannelOptions(credentials: ChannelCredentials.insecure())),
        _options = CallOptions(metadata: {if (endpoint.token.isNotEmpty) 'authorization': 'Bearer ${endpoint.token}'});

  final EmulatorEndpoint endpoint;
  final ClientChannel _channel;
  final CallOptions _options;

  static const _service = '/android.emulation.control.EmulatorController';

  ClientMethod<List<int>, List<int>> _method(String name) =>
      ClientMethod<List<int>, List<int>>('$_service/$name', (v) => v, (v) => v);

  late final _client = _RawClient(_channel);

  /// What the emulator plays, as PCM chunks with their capture time in microseconds since the epoch.
  ResponseStream<List<int>> streamAudio() =>
      _client.$createStreamingCall(_method('streamAudio'), Stream.value(_audioFormat()), options: _options);

  /// Replaces the emulator's environment (the `environment.ini` keys behind the `environment` camera) and reloads it at once, even while a camera is open.
  Future<void> setEnvironment(Map<String, String> entries) => _client.$createUnaryCall(
        _method('setEnvironment'),
        [
          for (final e in entries.entries)
            ..._lengthDelimited(1, [..._lengthDelimited(1, utf8.encode(e.key)), ..._lengthDelimited(2, utf8.encode(e.value))]),
        ],
        options: _options,
      );

  static List<int> _lengthDelimited(int field, List<int> bytes) => [(field << 3) | 2, ..._varint(bytes.length), ...bytes];

  /// Sets the emulator's GPS fix from an encoded `GpsState` message.
  Future<void> setGps(List<int> gpsState) => _client.$createUnaryCall(_method('setGps'), gpsState, options: _options);

  Future<void> close() => _channel.shutdown();

  static List<int> _audioFormat() => [0x08, ..._varint(sampleRate), 0x10, 0, 0x18, 1];

  /// The PCM bytes and timestamp in an `AudioPacket` reply.
  static ({Uint8List audio, int timestampUs}) readPacket(List<int> bytes) {
    var i = 0;
    var ts = 0;
    var audio = Uint8List(0);
    while (i < bytes.length) {
      final (key, k) = _decodeVarint(bytes, i);
      i = k;
      final field = key >> 3;
      final wire = key & 7;
      if (wire == 0) {
        final (v, j) = _decodeVarint(bytes, i);
        i = j;
        if (field == 2) ts = v;
      } else if (wire == 2) {
        final (len, j) = _decodeVarint(bytes, i);
        if (field == 3) audio = Uint8List.fromList(bytes.sublist(j, j + len));
        i = j + len;
      } else {
        break;
      }
    }
    return (audio: audio, timestampUs: ts);
  }

  static List<int> _varint(int v) {
    final out = <int>[];
    var n = v;
    while (n >= 0x80) {
      out.add((n & 0x7F) | 0x80);
      n >>= 7;
    }
    out.add(n);
    return out;
  }

  static (int, int) _decodeVarint(List<int> bytes, int start) {
    var result = 0;
    var shift = 0;
    var i = start;
    while (i < bytes.length) {
      final b = bytes[i++];
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    return (result, i);
  }
}

class _RawClient extends Client {
  _RawClient(super.channel);
}
