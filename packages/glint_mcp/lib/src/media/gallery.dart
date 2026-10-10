import 'dart:io';

import '../interaction/device.dart';
import 'host_tools.dart';
import 'seed_ledger.dart';

/// A step against a device failed in a way worth reporting; [detail] is the tool's own message.
class GalleryError implements Exception {
  GalleryError(this.summary, this.detail, {this.nextSteps = const []});
  final String summary;
  final String detail;
  final List<String> nextSteps;

  @override
  String toString() => '$summary: $detail';
}

/// The device a media call acts on: an iOS simulator by UDID or an Android device by adb serial.
class MediaDevice {
  const MediaDevice(this.platform, this.id, {this.adbPath = 'adb'});

  final DevicePlatform platform;
  final String id;
  final String adbPath;

  bool get isIos => platform == DevicePlatform.ios;

  /// Simulator UDIDs are UUIDs; anything else is an adb serial.
  static DevicePlatform platformOf(String id) =>
      RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').hasMatch(id)
          ? DevicePlatform.ios
          : DevicePlatform.android;

  /// Runs adb against this device only: `-s` always comes first, so another attached phone is never reached.
  Future<HostRun> adb(List<String> args, {Duration timeout = const Duration(minutes: 2)}) =>
      runHost(adbPath, ['-s', id, ...args], timeout: timeout);

  Future<HostRun> simctl(List<String> args, {Duration timeout = const Duration(minutes: 2)}) =>
      runHost('xcrun', ['simctl', ...args], timeout: timeout);

  String get photosDb => '${Platform.environment['HOME']}/Library/Developer/CoreSimulator/Devices/$id/data/Media/PhotoData/Photos.sqlite';
  String get dcimDir => '${Platform.environment['HOME']}/Library/Developer/CoreSimulator/Devices/$id/data/Media/DCIM';
}

/// Directory on an Android device where a file of [kind] belongs.
String androidDirFor(String kind) => switch (kind) {
      'video' => '/sdcard/Movies',
      'audio' => '/sdcard/Music',
      _ => '/sdcard/Pictures',
    };

/// Seeds and clears gallery media on one device.
class Gallery {
  Gallery(this.device);
  final MediaDevice device;

  /// Adds [staged] (a file already named for the gallery) to the device gallery and returns the ledger entry.
  Future<SeededAsset> add(File staged, {required String name, required String kind}) =>
      device.isIos ? _addIos(staged, name, kind) : _addAndroid(staged, name, kind);

  /// Removes [assets] from an Android gallery; returns the file names it could not remove. The iOS simulator has no supported way to delete from Photos.
  Future<List<String>> remove(List<SeededAsset> assets) => _removeAndroid(assets);

  Future<SeededAsset> _addIos(File staged, String name, String kind) async {
    if (kind == 'audio') {
      throw GalleryError('the Photos library takes no audio files',
          'simctl addmedia accepts photos and videos only, so ${staged.uri.pathSegments.last} cannot be added');
    }
    final run = await device.simctl(['addmedia', device.id, staged.path]);
    if (!run.ok) throw GalleryError('simctl addmedia failed', run.errTail());
    final file = staged.uri.pathSegments.last;
    final row = await _photosRow(file);
    return SeededAsset(
      name: name,
      kind: kind,
      file: file,
      sizeBytes: staged.lengthSync(),
      addedAt: DateTime.now(),
      devicePath: row?.path,
      assetId: row?.uuid,
    );
  }

  Future<({String uuid, String path})?> _photosRow(String originalFile) async {
    final sqlite = findHostBinary('sqlite3');
    if (sqlite == null) return null;
    for (var attempt = 0; attempt < 10; attempt++) {
      final run = await runHost(sqlite, [
        '-readonly',
        device.photosDb,
        "select a.ZUUID, a.ZDIRECTORY || '/' || a.ZFILENAME from ZASSET a join ZADDITIONALASSETATTRIBUTES b on b.ZASSET = a.Z_PK "
            "where b.ZORIGINALFILENAME = '${originalFile.replaceAll("'", "''")}' and a.ZTRASHEDSTATE = 0 order by a.Z_PK desc limit 1",
      ], timeout: const Duration(seconds: 10));
      final parts = run.text.trim().split('|');
      if (run.ok && parts.length == 2) return (uuid: parts[0], path: parts[1]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  Future<SeededAsset> _addAndroid(File staged, String name, String kind) async {
    final file = staged.uri.pathSegments.last;
    final path = '${androidDirFor(kind)}/$file';
    final exists = await device.adb(['shell', 'ls', path]);
    if (exists.ok) {
      throw GalleryError('$path already exists on the device', 'glint never overwrites a file it did not just create',
          nextSteps: const ['pass another name:', '`media op:seed clear:true` first if glint seeded that file earlier']);
    }
    final push = await device.adb(['push', staged.path, path]);
    if (!push.ok) throw GalleryError('adb push failed', push.errTail());
    await _scan(path);
    return SeededAsset(name: name, kind: kind, file: file, sizeBytes: staged.lengthSync(), addedAt: DateTime.now(), devicePath: path);
  }

  /// Has MediaStore index [path] (or forget it when the file is gone) through the scan_file provider call.
  Future<void> _scan(String path) async {
    final scan = await device.adb(['shell', 'content', 'call', '--uri', 'content://media/external/file', '--method', 'scan_file', '--arg', path]);
    if (scan.ok) return;
    final broadcast = await device.adb(['shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE', '-d', 'file://$path']);
    if (!broadcast.ok) throw GalleryError('MediaStore did not index $path', scan.errTail());
  }

  Future<List<String>> _removeAndroid(List<SeededAsset> assets) async {
    final failed = <String>[];
    for (final a in assets) {
      final path = a.devicePath;
      if (path == null || !path.startsWith('/sdcard/')) {
        failed.add(a.file);
        continue;
      }
      final rm = await device.adb(['shell', 'rm', '-f', path]);
      if (!rm.ok) {
        failed.add(a.file);
        continue;
      }
      await _scan(path);
    }
    return failed;
  }
}
