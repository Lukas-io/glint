import 'dart:convert';
import 'dart:io';

/// One remembered attach: an app ↔ device ↔ project triple, persisted so
/// `attach` can relaunch from a cold machine instead of dead-ending. Local
/// only (`~/.glint/attach-history.json`) — never shipped off the machine.
class AttachRecord {
  AttachRecord({
    required this.appKey,
    this.displayName,
    this.bundleId,
    required this.deviceId,
    required this.platform,
    this.deviceName,
    this.osVersion,
    this.projectDir,
    required this.firstSeen,
    required this.lastSeen,
    this.attachCount = 1,
  });

  /// App identity — the pubspec package name when known, else a project-dir
  /// basename or bundle id. Half of the dedup key.
  final String appKey;
  final String? displayName;
  final String? bundleId;

  /// iOS UDID or Android serial. The other half of the dedup key.
  final String deviceId;
  final String platform; // 'ios' | 'android'
  final String? deviceName;
  final String? osVersion;

  /// Flutter project root, for relaunch. Null when it couldn't be recovered —
  /// the record still identifies the app/device but can't be auto-launched.
  final String? projectDir;

  final DateTime firstSeen;
  DateTime lastSeen;
  int attachCount;

  /// One record per (app, device); re-attaching the pair updates in place.
  String get key => '$appKey@$deviceId';

  /// Relaunchable unattended only when we know where to run from.
  bool get launchable => projectDir != null;

  String get label => displayName ?? appKey;

  Map<String, Object?> toJson() => {
        'appKey': appKey,
        if (displayName != null) 'displayName': displayName,
        if (bundleId != null) 'bundleId': bundleId,
        'deviceId': deviceId,
        'platform': platform,
        if (deviceName != null) 'deviceName': deviceName,
        if (osVersion != null) 'osVersion': osVersion,
        if (projectDir != null) 'projectDir': projectDir,
        'firstSeen': firstSeen.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'attachCount': attachCount,
      };

  static AttachRecord? fromJson(Map<String, Object?> j) {
    final appKey = j['appKey'] as String?;
    final deviceId = j['deviceId'] as String?;
    final platform = j['platform'] as String?;
    if (appKey == null || deviceId == null || platform == null) return null;
    return AttachRecord(
      appKey: appKey,
      displayName: j['displayName'] as String?,
      bundleId: j['bundleId'] as String?,
      deviceId: deviceId,
      platform: platform,
      deviceName: j['deviceName'] as String?,
      osVersion: j['osVersion'] as String?,
      projectDir: j['projectDir'] as String?,
      firstSeen: DateTime.tryParse(j['firstSeen'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      attachCount: (j['attachCount'] as int?) ?? 1,
    );
  }
}

/// Persistent, most-recent-first store of [AttachRecord]s. All disk access is
/// best-effort — a missing or corrupt file reads as empty, writes never throw.
class AttachHistory {
  AttachHistory({required this.dataDir, this.maxRecords = 20});

  final String dataDir;
  final int maxRecords;

  static const _fileName = 'attach-history.json';
  String get _path => '$dataDir/$_fileName';

  List<AttachRecord> load() {
    final file = File(_path);
    if (!file.existsSync()) return [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => AttachRecord.fromJson(m.cast<String, Object?>()))
          .whereType<AttachRecord>()
          .toList();
    } on Object {
      return [];
    }
  }

  /// Insert or update the record for [incoming.key]: an existing entry keeps
  /// its `firstSeen` and bumps `attachCount`. Re-sorts most-recent-first,
  /// caps at [maxRecords], and writes.
  void record(AttachRecord incoming) {
    try {
      final list = load();
      final idx = list.indexWhere((r) => r.key == incoming.key);
      if (idx >= 0) {
        final prev = list.removeAt(idx);
        incoming = AttachRecord(
          appKey: incoming.appKey,
          displayName: incoming.displayName ?? prev.displayName,
          bundleId: incoming.bundleId ?? prev.bundleId,
          deviceId: incoming.deviceId,
          platform: incoming.platform,
          deviceName: incoming.deviceName ?? prev.deviceName,
          osVersion: incoming.osVersion ?? prev.osVersion,
          projectDir: incoming.projectDir ?? prev.projectDir,
          firstSeen: prev.firstSeen,
          lastSeen: incoming.lastSeen,
          attachCount: prev.attachCount + 1,
        );
      }
      list.insert(0, incoming);
      list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      _write(list.take(maxRecords).toList());
    } on Object {
      // best-effort — history is a convenience, never a hard dependency
    }
  }

  /// Best match for [query]: null / `true` / `last` → most recent; otherwise an
  /// exact appKey or projectDir, then a projectDir basename match.
  AttachRecord? find(String? query) {
    final list = load();
    if (list.isEmpty) return null;
    if (query == null || query == 'true' || query == 'last') return list.first;
    for (final r in list) {
      if (r.appKey == query || r.projectDir == query) return r;
    }
    for (final r in list) {
      if (r.projectDir != null && r.projectDir!.endsWith('/$query')) return r;
    }
    return null;
  }

  void _write(List<AttachRecord> list) {
    final file = File(_path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ')
          .convert(list.map((r) => r.toJson()).toList()),
    );
  }
}
