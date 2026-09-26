import 'dart:io';

import 'package:glint_mcp/observability.dart';
import 'package:test/test.dart';

void main() {
  group('sharing', () {
    test('is off unless the user opts in', () {
      expect(sharingEnabled(const {}), isFalse);
      expect(sharingOffReason(const {}), contains('GLINT_TELEMETRY=on'));
      expect(sharingEnabled(const {'GLINT_TELEMETRY': 'on'}), isTrue);
    });

    test('DO_NOT_TRACK and the old kill switches always win', () {
      expect(
          sharingEnabled(const {'GLINT_TELEMETRY': '1', 'DO_NOT_TRACK': '1'}),
          isFalse);
      expect(
          sharingEnabled(
              const {'GLINT_TELEMETRY': '1', 'GLINT_NO_TELEMETRY': 'true'}),
          isFalse);
      expect(
          sharingEnabled(
              const {'GLINT_TELEMETRY': '1', 'GLINT_NO_USAGE': 'yes'}),
          isFalse);
    });
  });

  test('ship sends nothing when the user has not opted in', () async {
    final dir = Directory.systemTemp.createTempSync('glint-ship-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final r = UsageRecorder.config(enabled: true)
      ..record(
          tool: 'tap',
          outcome: ToolOutcome.ok,
          argKeys: const [],
          durationMs: 1,
          resultBytes: 0);
    final res = await UsageReporter(r, env: const {}).ship(
        dataDir: dir.path, endpointOverride: 'http://127.0.0.1:1/v1/telemetry');
    expect(res.shipped, isFalse);
    expect(res.message, contains('GLINT_TELEMETRY=on'));
    expect(Directory(dir.path).listSync(), isEmpty);
  });

  test('the install id is random, stable and never derived from the path', () {
    final dir = Directory.systemTemp.createTempSync('glint-id-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final id = installId(dir.path);
    expect(id, matches(RegExp(r'^[0-9a-f]{24}$')));
    expect(installId(dir.path), id);
    final other = Directory.systemTemp.createTempSync('glint-id-');
    addTearDown(() => other.deleteSync(recursive: true));
    expect(installId(other.path), isNot(id));
  });
}
