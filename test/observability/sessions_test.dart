import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('SessionManager', () {
    test('open creates an active session', () {
      final mgr = SessionManager();
      final s = mgr.open('flow A', 5);
      expect(mgr.active, s);
      expect(s.name, 'flow A');
      expect(s.firstSeq, 5);
      expect(s.isActive, isTrue);
    });

    test('opening a new session auto-closes the previous', () {
      final mgr = SessionManager();
      final a = mgr.open('flow A', 0);
      final b = mgr.open('flow B', 4);
      expect(a.isActive, isFalse);
      expect(a.endedAt, isNotNull);
      expect(a.lastSeq, 3);
      expect(mgr.active, b);
    });

    test('close marks lastSeq and clears active', () {
      final mgr = SessionManager();
      mgr.open('flow', 10);
      final s = mgr.close(15);
      expect(s, isNotNull);
      expect(s!.lastSeq, 14);
      expect(mgr.active, isNull);
    });

    test('close with no active session returns null', () {
      final mgr = SessionManager();
      expect(mgr.close(0), isNull);
    });

    test('note appends to the active session only', () {
      final mgr = SessionManager();
      expect(mgr.note('orphan'), isFalse);
      mgr.open('flow', 0);
      expect(mgr.note('bug appeared'), isTrue);
      expect(mgr.active!.notes.single.text, 'bug appeared');
    });

    test('byId looks up across history including closed', () {
      final mgr = SessionManager();
      final a = mgr.open('a', 0);
      mgr.close(2);
      mgr.open('b', 2);
      expect(mgr.byId(a.id), a);
    });
  });
}
