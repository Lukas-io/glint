import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('buildCrashPayload', () {
    test('has the required schema fields + correct kind/version', () {
      final stack = StackTrace.fromString(
        '#0 SceneReader.readSummary (package:glint/src/perception/scene_reader.dart:42)\n'
        '#1 main (/Users/anyone/StudioProjects/glint/bin/glint.dart:10:5)',
      );
      final payload = buildCrashPayload(
        error: StateError('inspector eval failed'),
        stack: stack,
        dataDir: '/tmp/anywhere',
      );
      expect(payload['kind'], 'crash');
      expect(payload['version'], startsWith('glint/'));
      expect(payload['errorClass'], 'StateError');
      expect(payload['errorMessage'], contains('inspector eval failed'));
      expect(payload['stackHead'], isA<List<Object?>>());
      expect(payload['signature'], isA<String>());
      expect((payload['signature'] as String).length, 12);
      expect(payload['machineHash'], isA<String>());
      expect(payload['reportedAt'], matches(r'^\d{4}-\d{2}-\d{2}T'));
      expect(payload['os'], isA<String>());
      expect(payload['dart'], isA<String>());
    });

    test('stackHead has homedir paths redacted', () {
      final stack = StackTrace.fromString(
        '#0 main (/Users/lukasio/StudioProjects/glint/bin/glint.dart:10:5)',
      );
      final payload = buildCrashPayload(
        error: Exception('boom'),
        stack: stack,
        dataDir: '/tmp/x',
      );
      final head = (payload['stackHead'] as List).cast<String>();
      expect(head.any((line) => line.contains('lukasio')), isFalse);
      expect(head.any((line) => line.contains('<project:glint>')), isTrue);
    });

    test('errorMessage is truncated past kErrorMessageMaxChars', () {
      final long = 'x' * (kErrorMessageMaxChars + 100);
      final payload = buildCrashPayload(
        error: Exception(long),
        stack: StackTrace.empty,
        dataDir: '/tmp/x',
      );
      final msg = payload['errorMessage'] as String;
      expect(msg.length, lessThanOrEqualTo(kErrorMessageMaxChars + 32));
      expect(msg, contains('…'));
    });
  });

  group('crashSignature', () {
    test('identical inputs collapse to one signature', () {
      final a = crashSignature('StateError', ['#0 foo', '#1 bar', '#2 baz']);
      final b = crashSignature('StateError', ['#0 foo', '#1 bar', '#2 baz']);
      expect(a, b);
      expect(a.length, 12);
    });

    test('different error classes produce different signatures', () {
      final a = crashSignature('StateError', ['#0 foo']);
      final b = crashSignature('ArgumentError', ['#0 foo']);
      expect(a, isNot(b));
    });

    test('only the top 3 frames matter for the signature', () {
      final a = crashSignature('E', ['#0 a', '#1 b', '#2 c', '#3 d']);
      final b = crashSignature('E', ['#0 a', '#1 b', '#2 c', '#3 different']);
      expect(a, b);
    });
  });
}
