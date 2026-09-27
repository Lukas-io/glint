import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:test/test.dart';

DeviceSetup _ios(int runtime, int xcode, int host, {String backend = 'indigo'}) => (
      platform: 'ios',
      backend: backend,
      runtimeMajor: runtime,
      runtime: 'iOS $runtime.0',
      xcodeMajor: xcode,
      hostMajor: host,
    );

void main() {
  group('judgeSetup', () {
    test('a CI-proven setup is verified', () {
      final v = judgeSetup(_ios(26, 26, 26));
      expect(v.status, SetupStatus.verified);
      expect(v.match!.evidence, contains('CI'));
    });

    test('indigo on Xcode 27 is partial and names #74', () {
      final v = judgeSetup(_ios(27, 27, 27));
      expect(v.status, SetupStatus.partial);
      expect(v.match!.issues.join(), contains('#74'));
    });

    test('dtuhid on Xcode 27 is verified, judged apart from indigo', () {
      final v = judgeSetup(_ios(27, 27, 27, backend: 'dtuhid'));
      expect(v.status, SetupStatus.verified);
      expect(v.match!.backend, 'dtuhid');
    });

    test('an unknown combination is untested and points at the closest proven one', () {
      final v = judgeSetup(_ios(27, 28, 27));
      expect(v.status, SetupStatus.untested);
      expect(v.closest!.runtimeMajor, 27);
    });

    test('Android matches on API level alone', () {
      final setup = (
        platform: 'android',
        backend: 'adb',
        runtimeMajor: 35,
        runtime: 'Android API 35',
        xcodeMajor: null,
        hostMajor: null,
      );
      expect(judgeSetup(setup).status, SetupStatus.verified);
    });
  });

  group('describeSetup', () {
    test('partial setups warn with their issues; untested ones ask to report failures', () {
      final partial = describeSetup(_ios(27, 27, 27));
      expect(partial.line, 'input: iOS 27.0, Xcode 27, macOS 27, indigo · partial');
      expect(partial.warnings.single, contains('known issues'));
      final untested = describeSetup(_ios(28, 28, 28));
      expect(untested.json['status'], 'untested');
      expect(untested.warnings.single, contains('untested'));
    });
  });

  group('reading the setup', () {
    test('iOS reads the simulator runtime and the macOS major', () async {
      final setup = await readIosSetup('ABC', 27, run: (exe, args) async {
        if (exe == 'sw_vers') return ProcessResult(0, 0, '27.0.1\n', '');
        return ProcessResult(0, 0,
            '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"ABC"}],'
            '"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"XYZ"}]}}', '');
      });
      expect((setup.runtimeMajor, setup.runtime, setup.hostMajor), (27, 'iOS 27.0', 27));
    });

    test('the bridge names the transport it opened', () async {
      late List<String> argv;
      final t = await readIosTransport('/b', 'ABC', 'auto', run: (_, a) async {
        argv = a;
        return ProcessResult(0, 0, 'hid dtuhid coresimulator 1171.7\n', '');
      });
      expect(argv, ['hid', 'ABC']);
      expect((t.transport, t.fallback, t.error), ('dtuhid', null, null));
    });

    test('auto reports why it fell back to indigo', () async {
      final t = await readIosTransport('/b', 'ABC', 'auto', run: (_, __) async => ProcessResult(0, 0,
          'hid indigo coresimulator 1171.7 (dtuhid unavailable: no reply within 4s)\n', ''));
      expect((t.transport, t.fallback), ('indigo', 'no reply within 4s'));
    });

    test('a forced transport is passed through, and its failure is reported', () async {
      late List<String> argv;
      final t = await readIosTransport('/b', 'ABC', 'dtuhid', run: (_, a) async {
        argv = a;
        return ProcessResult(0, 1, '', 'hid failed: the simulator has no service');
      });
      expect(argv, ['--hid', 'dtuhid', 'hid', 'ABC']);
      expect(t.transport, isNull);
      expect(t.error, contains('no service'));
    });

    test('Android reads the API level', () async {
      final setup = await readAndroidSetup('emulator-5554', 'adb',
          run: (_, __) async => ProcessResult(0, 0, '35\n', ''));
      expect(setup.runtimeMajor, 35);
    });
  });
}
