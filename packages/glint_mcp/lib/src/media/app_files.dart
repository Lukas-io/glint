import 'dart:io';

import 'gallery.dart';
import 'host_tools.dart';
import 'seed_ledger.dart';

/// A file in an app's sandbox.
class AppFile {
  const AppFile(this.path, this.sizeBytes, this.modified);

  /// Absolute: a host path on iOS, a device path on Android.
  final String path;
  final int sizeBytes;
  final DateTime modified;

  Map<String, Object?> toJson() => {'path': path, 'size': sizeBytes, 'modified': modified.toUtc().toIso8601String()};
}

/// What a listing found, newest first, plus what the cap hid.
class AppFileListing {
  const AppFileListing({required this.files, required this.total, required this.roots, this.notes = const []});
  final List<AppFile> files;
  final int total;
  final List<String> roots;
  final List<String> notes;
}

/// A glob over a file name (`*.mp4`), or over the whole path when it holds a slash.
RegExp globToRegExp(String glob) {
  final body = glob.split('').map((c) => switch (c) {
        '*' => '.*',
        '?' => '.',
        _ => RegExp.escape(c),
      }).join();
  return RegExp('^$body\$', caseSensitive: false);
}

bool globMatches(String glob, String path) {
  final target = glob.contains('/') ? path : path.split('/').last;
  return globToRegExp(glob).hasMatch(target);
}

/// Reads and pulls the files an app wrote in its sandbox.
class AppFiles {
  AppFiles(this.device, this.appId);
  final MediaDevice device;
  final String appId;

  static const _androidDirs = ['files', 'cache', 'app_flutter'];

  /// The iOS data container of the app on the simulator.
  Future<String> iosContainer() async {
    final run = await device.simctl(['get_app_container', device.id, appId, 'data'], timeout: const Duration(seconds: 20));
    if (!run.ok) throw GalleryError('no data container for $appId on this simulator', run.errTail());
    return run.text.trim();
  }

  /// The simulator-side file for [path] when it exists, so an iOS sandbox file is read in place; null on Android or when missing.
  Future<File?> iosFile(String path) async {
    if (!device.isIos) return null;
    final file = File(path.startsWith('/') ? path : '${await iosContainer()}/$path');
    return file.existsSync() ? file : null;
  }

  Future<AppFileListing> list({DateTime? since, String? glob}) async =>
      device.isIos ? _listIos(since, glob) : _listAndroid(since, glob);

  Future<AppFileListing> _listIos(DateTime? since, String? glob) async {
    final root = await iosContainer();
    final found = <AppFile>[];
    await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final stat = e.statSync();
      if (since != null && !stat.modified.isAfter(since)) continue;
      if (glob != null && !globMatches(glob, e.path.substring(root.length + 1))) continue;
      found.add(AppFile(e.path, stat.size, stat.modified));
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return AppFileListing(files: found, total: found.length, roots: [root]);
  }

  Future<Duration> _clockSkew() async {
    final before = DateTime.now();
    final run = await device.adb(['shell', 'date', '+%s'], timeout: const Duration(seconds: 15));
    final device_ = int.tryParse(run.text.trim());
    if (!run.ok || device_ == null) return Duration.zero;
    final mid = before.add(DateTime.now().difference(before) ~/ 2);
    return DateTime.fromMillisecondsSinceEpoch(device_ * 1000).difference(mid);
  }

  List<AppFile> _statLines(HostRun run, String prefix, Duration skew) => [
        for (final line in run.text.split('\n'))
          if (RegExp(r'^(\d+) (\d+) (.+)$').firstMatch(line.trim()) case final m?)
            AppFile(
              m.group(3)!.startsWith('/') ? m.group(3)! : '$prefix/${m.group(3)}',
              int.parse(m.group(2)!),
              DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(1)!) * 1000).subtract(skew),
            ),
      ];

  Future<AppFileListing> _listAndroid(DateTime? since, String? glob) async {
    final skew = await _clockSkew();
    final notes = <String>[];
    final files = <AppFile>[];
    final internalRoot = '/data/user/0/$appId';
    final internal = await device.adb(
        ['shell', "run-as $appId find ${_androidDirs.join(' ')} -type f -exec stat -c '%Y %s %n' {} + 2>/dev/null"],
        timeout: const Duration(seconds: 60));
    if (internal.text.contains('not debuggable') || internal.err.contains('not debuggable') || internal.text.contains('is unknown')) {
      notes.add('the app sandbox is not readable (run-as needs a debuggable build); only its external storage is listed');
    } else {
      files.addAll(_statLines(internal, internalRoot, skew));
    }
    final externalRoot = '/sdcard/Android/data/$appId';
    final external = await device.adb(['shell', "find $externalRoot -type f -exec stat -c '%Y %s %n' {} + 2>/dev/null"], timeout: const Duration(seconds: 60));
    files.addAll(_statLines(external, externalRoot, skew));
    final shown = [
      for (final f in files)
        if ((since == null || f.modified.isAfter(since)) && (glob == null || globMatches(glob, f.path.startsWith(internalRoot) ? f.path.substring(internalRoot.length + 1) : f.path)))
          f,
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    return AppFileListing(files: shown, total: shown.length, roots: [internalRoot, externalRoot], notes: notes);
  }

  /// Copies [path] (as listed, or relative to the app's data) to the host pulled folder; returns the host file.
  Future<File> pull(String path, {PhaseReporter? phases}) async {
    final out = File('${mediaDir('pulled')}/${device.id.substring(0, 8)}-${DateTime.now().millisecondsSinceEpoch}-${path.split('/').last}');
    if (device.isIos) {
      final root = await iosContainer();
      final source = File(path.startsWith('/') ? path : '$root/$path');
      if (!source.existsSync()) throw GalleryError('no such file in the app container', source.path);
      return source.copy(out.path);
    }
    final internalRoot = '/data/user/0/$appId';
    final relative = path.startsWith('$internalRoot/') ? path.substring(internalRoot.length + 1) : (path.startsWith('/') ? null : path);
    Future<File> copy() async {
      if (relative == null) {
        final run = await device.adb(['pull', path, out.path], timeout: const Duration(minutes: 10));
        if (!run.ok) throw GalleryError('adb pull failed for $path', run.errTail());
        return out;
      }
      final process = await Process.start(device.adbPath, ['-s', device.id, 'exec-out', 'run-as', appId, 'cat', relative]);
      final sink = out.openWrite();
      await process.stdout.pipe(sink);
      final code = await process.exitCode;
      if (code != 0 || out.lengthSync() == 0) {
        if (out.existsSync()) out.deleteSync();
        throw GalleryError('could not read $relative from the app sandbox', 'run-as $appId cat exited $code (is the build debuggable?)');
      }
      return out;
    }

    return phases == null ? copy() : phases.during('pulling ${path.split('/').last}', copy);
  }
}
