import 'package:glint_network/src/tools/logs_tail.dart';
import 'package:test/test.dart';

void main() {
  test('truncateMessage never splits a surrogate pair', () {
    final t = truncateMessage('ab😀cd', 3);
    expect(t.message, 'ab');
    expect(t.truncated, isTrue);
    expect(t.totalLength, 6);
  });
}
