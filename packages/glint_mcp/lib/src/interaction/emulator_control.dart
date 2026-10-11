import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

/// The gRPC endpoint every running Android emulator serves, read from its `pid_<n>.ini` in the AVD running directory.
class EmulatorEndpoint {
  const EmulatorEndpoint({required this.port, required this.token});
  final int port;
  final String token;

  /// The endpoint of the emulator behind adb [serial] (`emulator-5554`), or null when none is running or it serves no gRPC.
  static EmulatorEndpoint? find(String serial, {Map<String, String>? env}) {
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
        final ini = _parseIni(f.readAsStringSync());
        if (ini['port.serial'] != consolePort) continue;
        final port = int.tryParse(ini['grpc.port'] ?? '');
        if (port == null) return null;
        return EmulatorEndpoint(port: port, token: ini['grpc.token'] ?? '');
      }
    }
    return null;
  }

  static Map<String, String> _parseIni(String text) => {
        for (final line in text.split('\n'))
          if (line.contains('=')) line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
      };
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
