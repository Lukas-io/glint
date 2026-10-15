import 'dart:io';

import 'device_hid.dart';
import 'image_size.dart';
import 'ocr.dart';

/// Answers a system prompt glint's own action raised on a phone: reads the screen with OCR and taps [button] when [question] is up; the question it answered, or null.
Future<String?> answerPhonePrompt(DeviceHid hid, String udid,
    {required RegExp question, required String button}) async {
  try {
    final path = '${Directory.systemTemp.path}/glint-prompt-$udid.png';
    await hid.call({'cmd': 'screenshot', 'path': path}, timeout: const Duration(seconds: 10));
    final size = pngSize(path);
    if (size == null) return null;
    final lines = await readText(path);
    final asked = lines.where((l) => question.hasMatch(l.text)).firstOrNull;
    final target = lines.where((l) => l.text.trim().toLowerCase() == button.toLowerCase()).firstOrNull;
    if (asked == null || target == null) return null;
    final x = ((target.x + target.w / 2) / size.$1 * 65535).round();
    final y = ((target.y + target.h / 2) / size.$2 * 65535).round();
    await hid.call({
      'cmd': 'touch',
      'points': [
        [x, y, 0],
        [x, y, 50],
      ],
    });
    return asked.text.trim();
  } on Object {
    return null;
  }
}

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
    answered = await answerPhonePrompt(_hid, udid, question: _question, button: 'Allow');
  }

  /// Keeps looking for a while after launch: Flutter can find the VM service before iOS shows the prompt.
  Future<void> afterLaunch({Duration within = const Duration(seconds: 8)}) async {
    final until = DateTime.now().add(within);
    while (answered == null && DateTime.now().isBefore(until)) {
      answered = await answerPhonePrompt(_hid, udid, question: _question, button: 'Allow');
      if (answered == null) await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }

  Future<void> close() => _hid.stop();
}
