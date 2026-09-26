import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Tamper-evident telemetry log at `<dataDir>/telemetry-audit.log`: one `<ts>|<prev_hash>|<payload_b64>|<this_hash>` line per payload, each hash covering the line before it, like `git log`.
class AuditLog {
  static const String fileName = 'telemetry-audit.log';
  static const String _zeroHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  /// Records [payloadJson], the exact bytes sent or about to be sent; an exclusive file lock keeps concurrent servers from forking the chain or losing lines. Throws on filesystem failure.
  static AuditEntry append(String dataDir, String payloadJson) {
    final file = io.File(_filePath(dataDir));
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: io.FileMode.append);
    try {
      raf.lockSync(io.FileLock.blockingExclusive);
      final prevHash = _lastHash(raf) ?? _zeroHash;
      final ts = DateTime.now().toUtc().toIso8601String();
      final payloadB64 = base64.encode(utf8.encode(payloadJson));
      final preimage = '$ts|$prevHash|$payloadB64';
      final thisHash = sha256.convert(utf8.encode(preimage)).toString();
      // FileMode.append positions at open time, not per write; another server may have appended while this one waited for the lock.
      raf.setPositionSync(raf.lengthSync());
      raf.writeStringSync('$preimage|$thisHash\n');
      raf.flushSync();
      return AuditEntry(
        ts: DateTime.parse(ts),
        prevHash: prevHash,
        payloadB64: payloadB64,
        thisHash: thisHash,
      );
    } finally {
      raf.closeSync();
    }
  }

  /// Every entry, with null where a line is malformed so [verify] can point at it.
  static List<AuditEntry?> readAll(String dataDir) {
    final file = io.File(_filePath(dataDir));
    if (!file.existsSync()) return const [];
    final out = <AuditEntry?>[];
    for (final raw in file.readAsLinesSync()) {
      if (raw.isEmpty) continue;
      out.add(AuditEntry.tryParse(raw));
    }
    return out;
  }

  /// Walks the chain and reports the first line whose hash no longer matches or whose link points nowhere; a link to an earlier line other than the last is a fork from concurrent writers before appends were locked, counted in [AuditVerifyResult.forks].
  static AuditVerifyResult verify(String dataDir) {
    final entries = readAll(dataDir);
    if (entries.isEmpty) {
      return const AuditVerifyResult(totalEntries: 0, intact: true);
    }
    final seen = <String>{};
    var previousThisHash = _zeroHash;
    var forks = 0;
    AuditVerifyResult broken(int i, String reason) => AuditVerifyResult(
          totalEntries: entries.length,
          intact: false,
          brokenAtIndex: i,
          brokenReason: reason,
          forks: forks,
          firstTs: entries.first?.ts,
        );
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry == null) return broken(i, 'malformed line');
      final linksPrevious = entry.prevHash == previousThisHash;
      if (!linksPrevious && !seen.contains(entry.prevHash)) {
        return broken(
            i,
            'prev_hash mismatch (expected ${_short(previousThisHash)}, '
            'got ${_short(entry.prevHash)})');
      }
      if (!linksPrevious) forks++;
      final preimage = '${entry.ts.toIso8601String()}|${entry.prevHash}|${entry.payloadB64}';
      final recomputed = sha256.convert(utf8.encode(preimage)).toString();
      if (recomputed != entry.thisHash) {
        return broken(
            i,
            'this_hash mismatch (recomputed ${_short(recomputed)}, '
            'recorded ${_short(entry.thisHash)})');
      }
      seen.add(entry.thisHash);
      previousThisHash = entry.thisHash;
    }
    return AuditVerifyResult(
      totalEntries: entries.length,
      intact: true,
      forks: forks,
      firstTs: entries.first?.ts,
      lastTs: entries.last?.ts,
    );
  }

  static String _filePath(String dataDir) => p.join(dataDir, fileName);

  /// The last line's hash, read through the locked handle: opening the file again and closing it would drop this process's lock.
  static String? _lastHash(io.RandomAccessFile raf) {
    final length = raf.lengthSync();
    var chunk = 4096;
    while (true) {
      final start = length > chunk ? length - chunk : 0;
      raf.setPositionSync(start);
      final text = utf8.decode(raf.readSync(length - start), allowMalformed: true);
      final lines = text.split('\n').where((l) => l.isNotEmpty).toList();
      final complete = start == 0 ? lines : lines.skip(1).toList();
      for (final line in complete.reversed) {
        final parts = line.split('|');
        if (parts.length == 4) return parts[3];
      }
      if (start == 0) return null;
      chunk *= 4;
    }
  }

  static String _short(String hash) =>
      hash.length <= 12 ? hash : '${hash.substring(0, 12)}…';
}

class AuditEntry {
  const AuditEntry({
    required this.ts,
    required this.prevHash,
    required this.payloadB64,
    required this.thisHash,
  });

  final DateTime ts;
  final String prevHash;
  final String payloadB64;
  final String thisHash;

  String decodePayload() => utf8.decode(base64.decode(payloadB64));

  static AuditEntry? tryParse(String line) {
    final parts = line.split('|');
    if (parts.length != 4) return null;
    final ts = DateTime.tryParse(parts[0]);
    if (ts == null) return null;
    if (parts[1].length != 64 || parts[3].length != 64) return null;
    return AuditEntry(
      ts: ts,
      prevHash: parts[1],
      payloadB64: parts[2],
      thisHash: parts[3],
    );
  }
}

class AuditVerifyResult {
  const AuditVerifyResult({
    required this.totalEntries,
    required this.intact,
    this.brokenAtIndex,
    this.brokenReason,
    this.forks = 0,
    this.firstTs,
    this.lastTs,
  });

  final int totalEntries;
  final bool intact;
  final int? brokenAtIndex;
  final String? brokenReason;

  /// Entries linked to an earlier line rather than the last one: written by two servers at once, before appends were locked.
  final int forks;
  final DateTime? firstTs;
  final DateTime? lastTs;
}
