import 'dart:io';

import 'device_hid.dart';
import 'image_size.dart';
import 'ocr.dart';

/// Watches a phone while a debug build launches and answers the local network prompt it raises, without which the VM service cannot be found.
class LocalNetworkPromptWatcher {
  LocalNetworkPromptWatcher(this.udid) : _hid = DeviceHid(udid: udid);

  final String udid;
  final DeviceHid _hid;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);

  /// The question it answered, once it has.
  String? answered;

  static const _every = Duration(seconds: 4);
  static final _question = RegExp('local network', caseSensitive: false);

  /// Looks at the phone at most every few seconds and taps Allow on the local network prompt when it is up.
  Future<void> check() async {
    if (answered != null || DateTime.now().isBefore(_next)) return;
    _next = DateTime.now().add(_every);
    try {
      final path = '${Directory.systemTemp.path}/glint-launch-$udid.png';
      await _hid.call({'cmd': 'screenshot', 'path': path}, timeout: const Duration(seconds: 10));
      final size = pngSize(path);
      if (size == null) return;
      final lines = await readText(path);
      final question = lines.where((l) => _question.hasMatch(l.text)).firstOrNull;
      final allow = lines.where((l) => l.text.trim().toLowerCase() == 'allow').firstOrNull;
      if (question == null || allow == null) return;
      final x = ((allow.x + allow.w / 2) / size.$1 * 65535).round();
      final y = ((allow.y + allow.h / 2) / size.$2 * 65535).round();
      await _hid.call({
        'cmd': 'touch',
        'points': [
          [x, y, 0],
          [x, y, 50],
        ],
      });
      answered = question.text.trim();
    } on Object {
      // the next poll looks again; the launch reports its own timeout
    }
  }

  Future<void> close() => _hid.stop();
}
