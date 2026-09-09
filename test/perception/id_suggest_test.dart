import 'package:glint/perception.dart';
import 'package:test/test.dart';

void main() {
  group('suggestIds', () {
    const ids = [
      'ink_well_in_send_button#a1b2',
      'ink_well_in_list_view#tiij',
      'text_in_list_view#nkhx',
      'gesture_detector_in_app_bar',
      'floating_action_button',
    ];

    test('a stale hash suffix maps to the same base first', () {
      final s = suggestIds(ids, 'ink_well_in_send_button#zzzz');
      expect(s.first, 'ink_well_in_send_button#a1b2');
    });

    test('a small typo is within edit distance', () {
      final s = suggestIds(ids, 'floating_action_buton');
      expect(s, contains('floating_action_button'));
    });

    test('a prefix of a longer id is suggested', () {
      final s = suggestIds(ids, 'gesture_detector');
      expect(s, contains('gesture_detector_in_app_bar'));
    });

    test('nothing close yields nothing', () {
      expect(suggestIds(ids, 'completely_unrelated_widget'), isEmpty);
      expect(didYouMean(const []), isNull);
    });

    test('didYouMean quotes each id', () {
      expect(didYouMean(['a', 'b']), 'did you mean: "a", "b"');
    });
  });
}
