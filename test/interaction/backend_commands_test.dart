import 'dart:io';

import 'package:glint/src/interaction/action.dart';
import 'package:glint/src/interaction/backends/adb_backend.dart';
import 'package:glint/src/interaction/backends/ios_sim_backend.dart';
import 'package:test/test.dart';

void main() {
  group('iOS bridge key argv', () {
    late List<List<String>> calls;
    IosSimBackend backend() {
      calls = [];
      return IosSimBackend(
        udid: 'UDID',
        deviceLogicalWidth: 402,
        deviceLogicalHeight: 874,
        devicePixelRatio: 3,
        binaryPath: '/bin/glint-iossim',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
    }

    test('pressKey sends usage, count and mask=0', () async {
      await backend().pressKey(KeyName.backspace, count: 3);
      expect(calls.single, ['/bin/glint-iossim', 'key', 'UDID', '42', '3', '0']);
    });

    test('modifiers become the mask', () async {
      await backend()
          .pressKey(KeyName.left, modifiers: const {KeyModifier.shift});
      expect(calls.single, ['/bin/glint-iossim', 'key', 'UDID', '80', '1', '2']);
    });

    test('selectAll is cmd+A', () async {
      await backend().selectAll();
      expect(calls.single, ['/bin/glint-iossim', 'key', 'UDID', '4', '1', '8']);
    });

    test('tapSequence is one taps call in logical points', () async {
      await backend().tapSequence([(x: 300, y: 600), (x: 600, y: 900)],
          intervalMs: 120);
      expect(calls.single, [
        '/bin/glint-iossim', 'taps', 'UDID', '402.0', '874.0', '120',
        '100.0', '200.0', '200.0', '300.0',
      ]);
    });

    test('typeText passes keyDelayMs as the gap, and omits it by default', () async {
      final b = backend();
      await b.typeText('07', keyDelayMs: 80);
      await b.typeText('07');
      expect(calls, [
        ['/bin/glint-iossim', 'type', 'UDID', '07', '80'],
        ['/bin/glint-iossim', 'type', 'UDID', '07'],
      ]);
    });

    test('a non-zero exit throws BackendToolError', () async {
      final b = IosSimBackend(
        udid: 'U',
        deviceLogicalWidth: 1,
        deviceLogicalHeight: 1,
        devicePixelRatio: 1,
        binaryPath: '/bin/x',
        run: (e, a) async => ProcessResult(0, 1, '', 'boom'),
      );
      expect(() => b.pressKey(KeyName.enter), throwsA(isA<Exception>()));
    });
  });

  group('adb key argv', () {
    late List<List<String>> calls;
    AdbBackend backend() {
      calls = [];
      return AdbBackend(
        deviceSerial: 'emu-1',
        adbPath: 'adb',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
    }

    test('pressKey with no modifiers repeats the keycode in one call', () async {
      await backend().pressKey(KeyName.backspace, count: 3);
      expect(calls.single,
          ['adb', '-s', 'emu-1', 'shell', 'input', 'keyevent', '67', '67', '67']);
    });

    test('modifiers use keycombination, once per count', () async {
      await backend()
          .pressKey(KeyName.enter, count: 2, modifiers: const {KeyModifier.ctrl});
      expect(calls, hasLength(2));
      expect(calls.first,
          ['adb', '-s', 'emu-1', 'shell', 'input', 'keycombination', '113', '66']);
    });

    test('selectAll is ctrl+A', () async {
      await backend().selectAll();
      expect(calls.single,
          ['adb', '-s', 'emu-1', 'shell', 'input', 'keycombination', '113', '29']);
    });
  });
}
