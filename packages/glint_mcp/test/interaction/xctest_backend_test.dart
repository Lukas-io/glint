import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:test/test.dart';

typedef _Call = (String method, String path, Map<String, Object?>? body);

XcTestRunner _runner(List<_Call> calls, {int code = 200, Map<String, Object?> reply = const {'done': 'ok'}}) =>
    XcTestRunner(
      udid: 'ABCD-1234',
      projectPath: '/nowhere/GlintRunner.xcodeproj',
      cacheDir: '/nowhere',
      http: (method, uri, body, _) async {
        calls.add((method, uri.path, body));
        return (code, reply);
      },
    );

XcTestBackend _backend(XcTestRunner runner) => XcTestBackend(
      runner: runner,
      sim: IosSimBackend(
        udid: 'ABCD-1234',
        deviceLogicalWidth: 402,
        deviceLogicalHeight: 874,
        devicePixelRatio: 3,
        binaryPath: '/bin/glint-iossim',
        run: (_, __) async => ProcessResult(0, 0, '', ''),
      ),
    );

void main() {
  group('XcTestRunner', () {
    test('each simulator gets a stable port in the runner range', () {
      final a = XcTestRunner.portFor('0C3A7933-FD3A-49CD-8DFA-EBAE08FA33B1');
      expect(XcTestRunner.portFor('0c3a7933-fd3a-49cd-8dfa-ebae08fa33b1'), a);
      expect(a, inInclusiveRange(22100, 22899));
      expect(XcTestRunner.portFor('A1F74AA6-3A01-40E9-8EA8-AFA4F2A5F242'), isNot(a));
    });

    test('a runner already answering with this protocol is reused, not rebuilt', () async {
      final calls = <_Call>[];
      final runner = _runner(calls, reply: {'runner': expectedRunnerProtocol});
      await runner.ensureStarted();
      expect(calls.map((c) => c.$2), ['/status']);
    });

    test('a refusal carries the runner\'s own reason', () async {
      final runner = _runner([], code: 400, reply: {'error': 'invalidArgument', 'detail': 'type needs text'});
      expect(
          () => runner.call('POST', '/type', body: const {}),
          throwsA(isA<XcTestRunnerError>()
              .having((e) => e.message, 'message', contains('invalidArgument'))
              .having((e) => e.detail, 'detail', 'type needs text')));
    });
  });

  group('XcTestBackend', () {
    test('taps in logical points', () async {
      final calls = <_Call>[];
      await _backend(_runner(calls)).tap(physicalX: 603, physicalY: 960);
      expect((calls.single.$1, calls.single.$2), ('POST', '/tap'));
      expect(calls.single.$3, {'x': 201.0, 'y': 320.0});
    });

    test('typing and keys name the app that holds focus', () async {
      final calls = <_Call>[];
      final b = _backend(_runner(calls))..bundleId = 'com.example.app';
      await b.typeText('hello');
      await b.pressKey(KeyName.backspace, count: 2, modifiers: const {KeyModifier.shift});
      expect(calls[0].$3, {'text': 'hello', 'app': 'com.example.app'});
      expect(calls[1].$3, {'key': 'backspace', 'count': 2, 'mods': ['shift'], 'app': 'com.example.app'});
    });

    test('a runner failure surfaces as a backend tool error with its reason', () async {
      final b = _backend(_runner([], code: 500, reply: {'error': 'xctestFailed', 'detail': 'no keyboard focus'}));
      expect(() => b.typeText('x'),
          throwsA(isA<BackendToolError>().having((e) => e.stderr, 'stderr', contains('no keyboard focus'))));
    });
  });
}
