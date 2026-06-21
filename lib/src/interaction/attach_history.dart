import 'dart:convert';
import 'dart:io';

/// A remembered app↔device↔project attach, persisted locally so `attach` can relaunch from cold.
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

  /// App identity — pubspec package name, else project-dir basename or bundle id.
  final String appKey;
  final String? displayName;
  final String? bundleId;

  /// iOS UDID or Android serial.
  final String deviceId;
  final String platform; // 'ios' | 'android'
  final String? deviceName;
  final String? osVersion;

  /// Flutter project root for relaunch; null when it couldn't be recovered.
  final String? projectDir;

  final DateTime firstSeen;
  DateTime lastSeen;
  int attachCount;

  /// Dedup key — one record per (app, device).
  String get key => '$appKey@$deviceId';

  /// Relaunchable unattended only when the project dir is known.
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

/// Persistent, most-recent-first [AttachRecord] store; all disk access is best-effort.
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

  /// Upsert by key (keeps `firstSeen`, bumps `attachCount`), re-sort, cap, write.
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

  /// Best match for [query]: null/`true`/`last` → most recent; else appKey, projectDir, or its basename.
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
