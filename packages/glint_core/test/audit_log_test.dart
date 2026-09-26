import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:glint_core/glint_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Directory makeTempDir() {
  return Directory.systemTemp.createTempSync('audit_log_test_');
}

void main() {
  group('AuditLog.append + verify', () {
    test('empty audit log verifies as intact', () {
      final dir = makeTempDir();
      try {
        final r = AuditLog.verify(dir.path);
        expect(r.intact, isTrue);
        expect(r.totalEntries, 0);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('appended entries form a verifiable chain', () {
      final dir = makeTempDir();
      try {
        AuditLog.append(dir.path, '{"a":1}');
        AuditLog.append(dir.path, '{"b":2}');
        AuditLog.append(dir.path, '{"c":3}');
        final r = AuditLog.verify(dir.path);
        expect(r.intact, isTrue);
        expect(r.totalEntries, 3);
        expect(r.firstTs, isNotNull);
        expect(r.lastTs, isNotNull);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('first entry prev_hash is 64 zeros', () {
      final dir = makeTempDir();
      try {
        AuditLog.append(dir.path, '{"first":true}');
        final entries = AuditLog.readAll(dir.path);
        expect(entries, hasLength(1));
        expect(entries.first!.prevHash,
            '0000000000000000000000000000000000000000000000000000000000000000');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('payload decode round-trips', () {
      final dir = makeTempDir();
      try {
        const payload = '{"version":"0.7.1","errorClass":"StateError"}';
        AuditLog.append(dir.path, payload);
        final entries = AuditLog.readAll(dir.path);
        expect(entries.first!.decodePayload(), payload);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('tampered payload breaks the chain', () {
      final dir = makeTempDir();
      try {
        AuditLog.append(dir.path, '{"a":1}');
        AuditLog.append(dir.path, '{"b":2}');
        // Tamper with line 0's payload field directly.
        final path = p.join(dir.path, AuditLog.fileName);
        final lines = File(path).readAsLinesSync();
        final parts = lines[0].split('|');
        parts[2] = base64.encode(utf8.encode('{"a":2}')); // changed value!
        lines[0] = parts.join('|');
        File(path).writeAsStringSync('${lines.join('\n')}\n');
        final r = AuditLog.verify(dir.path);
        expect(r.intact, isFalse);
        expect(r.brokenAtIndex, 0);
        expect(r.brokenReason, contains('this_hash mismatch'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('removed middle line breaks the chain via prev_hash mismatch', () {
      final dir = makeTempDir();
      try {
        AuditLog.append(dir.path, '{"a":1}');
        AuditLog.append(dir.path, '{"b":2}');
        AuditLog.append(dir.path, '{"c":3}');
        final path = p.join(dir.path, AuditLog.fileName);
        final lines = File(path).readAsLinesSync();
        lines.removeAt(1); // drop the middle entry
        File(path).writeAsStringSync('${lines.join('\n')}\n');
        final r = AuditLog.verify(dir.path);
        expect(r.intact, isFalse);
        expect(r.brokenAtIndex, 1);
        expect(r.brokenReason, contains('prev_hash mismatch'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('malformed line is detected at its position', () {
      final dir = makeTempDir();
      try {
        AuditLog.append(dir.path, '{"a":1}');
        AuditLog.append(dir.path, '{"b":2}');
        final path = p.join(dir.path, AuditLog.fileName);
        final lines = File(path).readAsLinesSync();
        lines[1] = 'not a valid audit line';
        File(path).writeAsStringSync('${lines.join('\n')}\n');
        final r = AuditLog.verify(dir.path);
        expect(r.intact, isFalse);
        expect(r.brokenAtIndex, 1);
        expect(r.brokenReason, 'malformed line');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('readAll returns empty list when file missing', () {
      final dir = makeTempDir();
      try {
        expect(AuditLog.readAll(dir.path), isEmpty);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  test('processes appending at the same time keep one unbroken chain', () async {
    final dir = Directory.systemTemp.createTempSync('audit-race');
    addTearDown(() => dir.deleteSync(recursive: true));
    final workers = await Future.wait([
      for (var w = 0; w < 4; w++)
        Process.start(Platform.resolvedExecutable,
            ['run', 'test/support/append_worker.dart', dir.path, '$w', '25']),
    ]);
    final codes = await Future.wait(workers.map((w) => w.exitCode));
    expect(codes, everyElement(0));
    final r = AuditLog.verify(dir.path);
    expect(r.totalEntries, 100);
    expect(r.intact, isTrue, reason: r.brokenReason);
    expect(r.forks, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('entries written by two servers before appends were locked', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('audit-fork'));
    tearDown(() => dir.deleteSync(recursive: true));

    String forged(String prevHash, String payload) {
      final ts = DateTime.utc(2026, 7, 3).toIso8601String();
      final b64 = base64.encode(utf8.encode(payload));
      final preimage = '$ts|$prevHash|$b64';
      return '$preimage|${sha256.convert(utf8.encode(preimage))}\n';
    }

    test('a link to an earlier line is a fork, not a break', () {
      final first = AuditLog.append(dir.path, '{"a":1}');
      AuditLog.append(dir.path, '{"b":2}');
      File(p.join(dir.path, AuditLog.fileName))
          .writeAsStringSync(forged(first.thisHash, '{"c":3}'), mode: FileMode.append);
      final r = AuditLog.verify(dir.path);
      expect(r.intact, isTrue, reason: r.brokenReason);
      expect(r.forks, 1);
    });

    test('a link to no line at all is still a break', () {
      AuditLog.append(dir.path, '{"a":1}');
      File(p.join(dir.path, AuditLog.fileName))
          .writeAsStringSync(forged('f' * 64, '{"c":3}'), mode: FileMode.append);
      final r = AuditLog.verify(dir.path);
      expect(r.intact, isFalse);
      expect(r.brokenAtIndex, 1);
    });
  });
}
