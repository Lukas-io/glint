import 'package:glint_core/glint_core.dart';
import 'package:test/test.dart';

void main() {
  test('editDistance counts single-character edits', () {
    expect(editDistance('', ''), 0);
    expect(editDistance('abc', ''), 3);
    expect(editDistance('kitten', 'sitting'), 3);
    expect(editDistance('deliveries', 'delivery'), 3);
    expect(editDistance('same', 'same'), 0);
  });
}
