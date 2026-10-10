import 'dart:convert';
import 'dart:io';

import '../observability/telemetry/env.dart';

/// One file glint put in a device gallery, kept so `clear` removes exactly that and nothing of the user's.
class SeededAsset {
  const SeededAsset({
    required this.name,
    required this.kind,
    required this.file,
    required this.sizeBytes,
    required this.addedAt,
    this.devicePath,
    this.assetId,
  });

  final String name;
  final String kind;

  /// File name the asset was added under; on iOS the Photos library keeps it as the original file name.
  final String file;
  final int sizeBytes;
  final DateTime addedAt;

  /// Where the file sits on an Android device, or in the simulator's DCIM folder on iOS.
  final String? devicePath;

  /// The Photos library UUID on iOS.
  final String? assetId;

  Map<String, Object?> toJson() => {
        'name': name,
        'kind': kind,
        'file': file,
        'size': sizeBytes,
        'path': devicePath,
        'assetId': assetId,
        'addedAt': addedAt.toIso8601String(),
      };

  static SeededAsset fromJson(Map<String, Object?> j) => SeededAsset(
        name: j['name'] as String,
        kind: j['kind'] as String,
        file: j['file'] as String,
        sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
        addedAt: DateTime.tryParse('${j['addedAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        devicePath: j['path'] as String?,
        assetId: j['assetId'] as String?,
      );
}

/// The per-device list of seeded assets under `<data dir>/media`.
class SeedLedger {
  SeedLedger(this.deviceId, {String? dataDir}) : _dir = '${dataDir ?? resolveDataDir()}/media';

  final String deviceId;
  final String _dir;

  File get _file => File('$_dir/seeded-${deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json');

  List<SeededAsset> load() {
    try {
      final raw = jsonDecode(_file.readAsStringSync()) as List;
      return [for (final e in raw) SeededAsset.fromJson((e as Map).cast<String, Object?>())];
    } on Object {
      return const [];
    }
  }

  void save(List<SeededAsset> assets) {
    Directory(_dir).createSync(recursive: true);
    if (assets.isEmpty) {
      if (_file.existsSync()) _file.deleteSync();
      return;
    }
    _file.writeAsStringSync(jsonEncode([for (final a in assets) a.toJson()]));
  }
}

/// `<data dir>/media/<sub>`, created when missing.
String mediaDir(String sub) {
  final dir = Directory('${resolveDataDir()}/media/$sub')..createSync(recursive: true);
  return dir.path;
}
