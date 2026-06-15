import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('version constants', () {
    test('packageVersion is a non-empty semver-shaped string', () {
      expect(packageVersion, isNotEmpty);
      expect(packageVersion, matches(r'^\d+\.\d+\.\d+'));
    });

    test('isAotBuild is a bool (the test runner is JIT so it should be false)',
        () {
      expect(isAotBuild, isFalse);
    });

    test('currentCommitSha returns null OR a hex-looking string', () {
      final sha = currentCommitSha();
      if (sha != null) {
        // git rev-parse output is 40 lower-hex chars.
        expect(sha, matches(r'^[0-9a-f]{7,40}$'));
      }
    });

    test('shortCommit is a 12-char prefix when SHA is present', () {
      final short = shortCommit();
      final full = currentCommitSha();
      if (full == null) {
        expect(short, isNull);
      } else if (full.length < 12) {
        expect(short, full);
      } else {
        expect(short, full.substring(0, 12));
      }
    });
  });
}
