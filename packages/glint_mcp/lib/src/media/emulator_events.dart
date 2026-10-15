import 'gallery.dart';

/// The events `media op:event` sends to an Android emulator.
const eventKinds = {'rotate', 'light', 'proximity', 'call', 'endCall', 'sms'};

const _rotations = {'portrait': 0, 'landscape': 1, 'reversePortrait': 2, 'reverseLandscape': 3};

/// An event the emulator did not take, or that read back differently.
class EventFailed implements Exception {
  EventFailed(this.summary, this.detail, {this.invalid = false});
  final String summary;
  final String detail;

  /// The arguments were wrong, rather than the device.
  final bool invalid;
}

/// Sends one [kind] event to the emulator [device] and returns what the device reports afterwards.
Future<String> sendEvent(MediaDevice device, String kind, {String? value, String? number, String? text}) async {
  Future<String> emu(List<String> args) async {
    final r = await device.adb(['emu', ...args]);
    final out = r.text.trim();
    if (!r.ok || out.contains('KO')) {
      throw EventFailed('the emulator console refused `${args.join(' ')}`', '$out ${r.errTail()}'.trim());
    }
    return out;
  }

  Future<String> shell(List<String> args) async => (await device.adb(['shell', ...args])).text.trim();

  final phone = number ?? '5551234';
  switch (kind) {
    case 'rotate':
      if (value == 'auto') {
        await shell(['settings', 'put', 'system', 'accelerometer_rotation', '1']);
        return 'auto-rotate is back on';
      }
      final r = _rotations[value];
      if (r == null) {
        throw EventFailed(
            'rotate needs value: ${[..._rotations.keys, 'auto'].join(' | ')}', 'got ${value ?? 'nothing'}',
            invalid: true);
      }
      await shell(['settings', 'put', 'system', 'accelerometer_rotation', '0']);
      await shell(['settings', 'put', 'system', 'user_rotation', '$r']);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final now = RegExp(r'mCurrentRotation=ROTATION_(\d+)')
          .firstMatch(await shell(['dumpsys', 'window', 'displays']))
          ?.group(1);
      if (now != '${r * 90}') {
        throw EventFailed('the display did not turn to $value', 'it reads ROTATION_${now ?? '?'}');
      }
      return 'the display is now $value (${r * 90} degrees); auto-rotate is off until `value:"auto"`';
    case 'light':
    case 'proximity':
      final reading = kind == 'light'
          ? double.tryParse(value ?? '')
          : switch (value) { 'near' => 0.0, 'far' => 5.0, _ => double.tryParse(value ?? '') };
      if (reading == null) {
        throw EventFailed(
            kind == 'light' ? 'light needs value: lux, e.g. 3 for a dark room' : 'proximity needs value: near | far',
            'got ${value ?? 'nothing'}',
            invalid: true);
      }
      await emu(['sensor', 'set', kind, '$reading']);
      final got = await emu(['sensor', 'get', kind]);
      return 'the $kind sensor reads ${got.split('\n').first.replaceAll(RegExp(r'\s*OK$'), '').trim()}';
    case 'call':
      await emu(['gsm', 'call', phone]);
      await Future<void>.delayed(const Duration(seconds: 1));
      final state = RegExp(r'mCallState=(\d)').firstMatch(await shell(['dumpsys', 'telephony.registry']))?.group(1);
      if (state != '1') throw EventFailed('the phone did not ring', 'call state reads ${state ?? '?'}');
      return 'an incoming call from $phone is ringing; `kind:"endCall"` hangs it up';
    case 'endCall':
      await emu(['gsm', 'cancel', phone]);
      await Future<void>.delayed(const Duration(seconds: 1));
      final state = RegExp(r'mCallState=(\d)').firstMatch(await shell(['dumpsys', 'telephony.registry']))?.group(1);
      return state == '0'
          ? 'the call from $phone ended'
          : 'asked to end the call from $phone; the call state reads ${state ?? '?'}';
    case 'sms':
      if (text == null || text.isEmpty) {
        throw EventFailed('sms needs text: the message body', 'got nothing', invalid: true);
      }
      await emu(['sms', 'send', phone, text]);
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final inbox = await shell(['content', 'query', '--uri', 'content://sms/inbox', '--projection', 'address:body']);
        final newest = RegExp(r'Row: 0 address=(.*?), body=(.*)').firstMatch(inbox);
        if (newest != null && newest.group(1) == phone && newest.group(2)!.trim() == text) {
          return 'an SMS from $phone arrived in the inbox (${text.length} chars)';
        }
      }
      return 'sent an SMS from $phone; the inbox did not show it within 4 s (the messaging app may still be storing it)';
  }
  throw EventFailed('kind must be one of ${eventKinds.join(' | ')}', 'got $kind', invalid: true);
}
