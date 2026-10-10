import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../interaction/image_size.dart';
import '../../media/app_files.dart';
import '../../media/gallery.dart';
import '../../media/host_tools.dart';
import '../../media/media_generate.dart';
import '../../media/media_inspect.dart';
import '../../media/seed_ledger.dart';
import '../../media/testcard_generator.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

const _actionTools = {'tap', 'long_press', 'swipe', 'drag', 'scroll', 'scroll_to_find', 'type', 'key', 'hardware_button', 'batch'};
const _generators = {'testcard', 'speech', 'tone'};
const _maxFramesReturned = 6;

/// `media` puts photos, videos and audio in the device gallery, lists and pulls what the app wrote, and inspects media files (a glint test card decodes to rotation, mirror, scale, frames and audio sync).
class MediaTool extends GlintTool {
  const MediaTool();

  @override
  Tool get definition => Tool(
        name: 'media',
        description: 'Media on the device. op: seed (add a photo, video or audio to the gallery from a host file or a generator: '
            'testcard, speech, tone; clear:true removes what glint seeded, Android only), files (what the app wrote, newest first; pull:true copies one to the host), '
            'inspect (ffprobe, loudness, frames as images; a glint testcard also decodes to rotation, mirror, scale, dropped frames, audio offset). '
            'Generators and inspect need ffmpeg. errorKind: invalidArgument, unsupportedToolchain, deviceGone, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'seed | files | inspect'),
            'device': Schema.string(description: 'Simulator UDID or adb serial. Default: the attached device.'),
            'kind': Schema.string(description: 'seed: photo | video | audio. Default: from source, else video.'),
            'source': Schema.string(description: 'seed: a host file path, or testcard | speech | tone. Default: testcard (tone for audio).'),
            'name': Schema.string(description: 'seed: asset name (also the file name). clear:true with name removes just that one.'),
            'count': Schema.int(description: 'seed testcard photo: how many photos. Default 1.'),
            'clear': Schema.bool(description: 'seed: remove what glint seeded on this device, nothing else. Android only.'),
            'size': Schema.string(description: 'testcard: WxH, even. Default 1080x1920.'),
            'durationSec': Schema.num(description: 'testcard video or tone: seconds. Default 6.'),
            'fps': Schema.int(description: 'testcard video: frames per second. Default 30.'),
            'rotation': Schema.int(description: 'testcard video: rotation tag 0 | 90 | 180 | 270 (clockwise). Default 0.'),
            'text': Schema.string(description: 'speech: what to say.'),
            'voice': Schema.string(description: 'speech: a macOS voice name.'),
            'hz': Schema.num(description: 'tone: frequency. Default 440.'),
            'since': Schema.string(description: 'files: lastAction (since the last tap, type, swipe ...) or an ISO time.'),
            'glob': Schema.string(description: 'files: e.g. *.mp4 (matches the file name, or the path when it has a /).'),
            'limit': Schema.int(description: 'files: cap on the list. Default 50, max 200.'),
            'pull': Schema.bool(description: 'files: copy path to the host and return the host path.'),
            'path': Schema.string(description: 'files pull / inspect: a host path, or a path from files.'),
            'appId': Schema.string(description: 'files: bundle id or package. Default: the attached app.'),
            'frames': Schema.list(description: 'inspect: times to return as images, seconds or start | middle | end (max $_maxFramesReturned).'),
            'probe': Schema.bool(description: 'inspect: false leaves out the metadata and loudness lines. Default true.'),
            'maxSize': Schema.int(description: 'inspect: longest side of returned frames (0 = full). Default: screenshotMaxSize.'),
          },
          required: ['op'],
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = args['op'] as String?;
    final phases = PhaseReporter(_progressSink(session, request));
    try {
      return switch (op) {
        'seed' => await _seed(session, args, phases),
        'files' => await _files(session, args, phases),
        'inspect' => await _inspect(session, args, phases),
        _ => _bad('op must be seed, files or inspect, got ${op ?? 'nothing'}'),
      };
    } on MissingHostTool catch (e) {
      return _missingTool(e, op);
    } on GalleryError catch (e) {
      return StructuredResponse.error(
        summary: e.summary,
        errorKind: GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: e.nextSteps.isEmpty ? const ['check the device is booted and reachable, then retry'] : e.nextSteps,
      );
    } on MediaUnreadable catch (e) {
      return StructuredResponse.error(
        summary: 'that file is not readable as media',
        errorKind: GlintErrorKind.invalidArgument,
        detail: e.detail,
        nextSteps: const ['pass a video, photo or audio file; for a file the app wrote, list it with `media op:files` first'],
      );
    }
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (elapsedSec, phase) => notifier(ProgressNotification(progressToken: token, progress: elapsedSec, message: '$phase (${elapsedSec}s)'));
  }

  StructuredResponse _bad(String summary, {String? detail, List<String> nextSteps = const []}) =>
      StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument, detail: detail, nextSteps: nextSteps);

  StructuredResponse _missingTool(MissingHostTool e, String? op) {
    final steps = switch (e.binary) {
      'ffmpeg' || 'ffprobe' => [
          'brew install ffmpeg (ffprobe comes with it), then retry',
          if (op == 'seed') 'or pass a host file as source: it needs no ffmpeg',
        ],
      'say' => ['offline speech needs macOS `say`', 'use source:"tone" or a host audio file instead'],
      _ => ['install ${e.binary} on the host, then retry'],
    };
    return StructuredResponse.error(
      summary: 'media ${op ?? ''} needs ${e.binary}, which is not available on the host'.replaceAll('  ', ' '),
      errorKind: GlintErrorKind.unsupportedToolchain,
      detail: e.toString(),
      nextSteps: steps,
    );
  }

  Future<MediaDevice?> _device(GlintSession session, Map<String, Object?> args, List<StructuredResponse> failure) async {
    final given = args['device'] as String?;
    final attached = session.isAttached ? session.device : null;
    final String id;
    String adbPath;
    if (given != null && given.isNotEmpty) {
      id = given;
      adbPath = attached is AndroidDevice ? attached.adbPath : (resolveAdbPath(null) ?? 'adb');
      if (!session.hasApp(id)) {
        final claim = DeviceClaims().heldByOther(id);
        if (claim != null) {
          failure.add(StructuredResponse.error(
            summary: 'device $id is driven by another glint session',
            errorKind: GlintErrorKind.deviceClaimed,
            detail: claim.describe,
            nextSteps: const ['pass the device this session attached, or ask the user before touching it'],
          ));
          return null;
        }
      }
    } else if (attached != null) {
      id = attached.id;
      adbPath = attached is AndroidDevice ? attached.adbPath : 'adb';
    } else {
      failure.add(StructuredResponse.error(
        summary: 'no device to act on: glint is not attached and no device was given',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['call `attach` (device mode works), or pass device:"<udid or adb serial>"'],
      ));
      return null;
    }
    final device = MediaDevice(MediaDevice.platformOf(id), id, adbPath: adbPath);
    final gone = await _reachable(device);
    if (gone != null) {
      failure.add(gone);
      return null;
    }
    return device;
  }

  Future<StructuredResponse?> _reachable(MediaDevice device) async {
    if (device.isIos) {
      if (await const SimControl().isBooted(device.id)) return null;
      return StructuredResponse.error(
        summary: 'simulator ${device.id} is not booted',
        errorKind: GlintErrorKind.deviceGone,
        nextSteps: ['attach device:"${device.id}" boots it', 'or xcrun simctl boot ${device.id}'],
      );
    }
    final state = await device.adb(['get-state'], timeout: const Duration(seconds: 15));
    if (state.ok && state.text.trim() == 'device') return null;
    return StructuredResponse.error(
      summary: 'adb does not see device ${device.id}',
      errorKind: GlintErrorKind.deviceGone,
      detail: state.errTail(),
      nextSteps: const ['start the emulator or reconnect the phone, then retry', '`attach` lists what is running'],
    );
  }

  String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  String _humanSize(int bytes) => bytes >= 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).toStringAsFixed(0)} KB';

  static const _kinds = {'photo', 'video', 'audio'};

  String? _kindOfExtension(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'heic', 'gif', 'webp', 'bmp'}.contains(ext)) return 'photo';
    if (const {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'}.contains(ext)) return 'video';
    if (const {'m4a', 'mp3', 'wav', 'aac', 'ogg', 'flac', 'aiff', 'caf'}.contains(ext)) return 'audio';
    return null;
  }

  Future<StructuredResponse> _seed(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final failure = <StructuredResponse>[];
    final target = await _device(session, args, failure);
    if (target == null) return failure.single;
    final device = target;
    final gallery = Gallery(device);
    final ledger = SeedLedger(device.id);
    if (argBool(args, 'clear') ?? false) return _clear(device, gallery, ledger, args['name'] as String?, phases);

    final rawSource = (args['source'] as String?)?.replaceFirst('generate:', '');
    final hostSource = rawSource != null && !_generators.contains(rawSource) ? rawSource : null;
    if (hostSource != null && !File(hostSource).existsSync()) {
      return _bad('source is neither a generator nor an existing file: $hostSource',
          nextSteps: const ['pass an absolute host path, or testcard | speech | tone']);
    }
    var kind = args['kind'] as String? ?? (hostSource != null ? _kindOfExtension(hostSource) : null);
    final generator = hostSource != null ? null : (rawSource ?? (kind == 'audio' ? 'tone' : 'testcard'));
    kind ??= generator == 'speech' || generator == 'tone' ? 'audio' : 'video';
    if (!_kinds.contains(kind)) return _bad('kind must be photo, video or audio, got $kind');
    if (generator == 'testcard' && kind == 'audio') return _bad('a testcard is a photo or video, not audio', nextSteps: const ['use kind:"video" or "photo", or source:"speech" | "tone" for audio']);
    if ((generator == 'speech' || generator == 'tone') && kind != 'audio') {
      return _bad('$generator makes audio, not $kind', nextSteps: const ['use kind:"audio"']);
    }
    if (device.isIos && kind == 'audio') {
      return StructuredResponse.error(
        summary: 'an iOS simulator gallery takes photos and videos, not audio files',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'simctl addmedia rejects audio, and the Photos library holds none',
        nextSteps: const ['on Android, seed kind:"audio" lands in Music', 'on iOS pass a video that carries the audio (kind:"video" with a host file)'],
      );
    }

    final base = _safe(args['name'] as String? ?? '${generator ?? 'file'}-${_stamp()}');
    final count = argInt(args, 'count') ?? 1;
    if (count < 1 || count > 50) return _bad('count must be 1 to 50, got $count');
    final staged = <(File, String)>[];
    if (hostSource != null) {
      final ext = hostSource.contains('.') ? '.${hostSource.split('.').last}' : '';
      final copy = await File(hostSource).copy('${mediaDir('staged')}/glint-$base$ext');
      staged.add((copy, base));
    } else {
      final (:spec, :error) = _cardSpec(args, kind: kind, count: count);
      if (error != null) return error;
      switch (generator) {
        case 'testcard' when kind == 'photo':
          final files = await generateTestCardPhotos(spec!, 'glint-$base', phases: phases);
          for (var i = 0; i < files.length; i++) {
            staged.add((files[i], files.length == 1 ? base : '$base-${i + 1}'));
          }
        case 'testcard':
          staged.add((await generateTestCardVideo(spec!, 'glint-$base', phases: phases), base));
        case 'speech':
          final text = args['text'] as String?;
          if (text == null || text.trim().isEmpty) return _bad('source speech needs text', nextSteps: const ['pass text:"what to say"']);
          staged.add((await generateSpeech(text, 'glint-$base', voice: args['voice'] as String?, phases: phases), base));
        case 'tone':
          final duration = argNum(args, 'durationSec') ?? 6;
          if (duration <= 0 || duration > 600) return _bad('durationSec must be above 0 and at most 600, got $duration');
          staged.add((await generateTone(argNum(args, 'hz') ?? 440, duration, 'glint-$base', phases: phases), base));
        default:
          return _bad('unknown source: $rawSource', nextSteps: const ['use testcard | speech | tone, or a host file path']);
      }
    }

    final added = <SeededAsset>[];
    final all = [...ledger.load()];
    for (final (file, name) in staged) {
      final asset = await phases.during('adding ${file.uri.pathSegments.last} to the gallery', () => gallery.add(file, name: name, kind: kind!));
      added.add(asset);
      ledger.save(all..add(asset));
    }
    final where = device.isIos ? 'Photos library' : 'MediaStore';
    final first = added.first;
    return StructuredResponse(
      summary: 'seeded ${added.length == 1 ? '${first.kind} "${first.name}" (${_humanSize(first.sizeBytes)})' : '${added.length} ${first.kind}s "${first.name}"..."${added.last.name}"'} '
          'into the ${device.id} $where${first.devicePath == null ? '' : ' at ${first.devicePath}'}',
      nextSteps: [
        if (device.isIos) 'open the app\'s picker (the system photo picker: Choose from library); the seeded item is the newest one'
        else 'open the app\'s picker (Photo Picker or Files); the seeded item is the newest one',
        if (kind == 'video' && generator == 'testcard') 'after the app exports it, `media op:files since:lastAction` then `media op:inspect path:<file>` decodes the card',
        if (device.isIos) 'to remove it later, delete the glint-${first.name} item in the Photos app (the simulator offers no delete)'
        else '`media op:seed clear:true` removes what glint seeded',
      ],
      data: {
        'device': device.id,
        'assets': [for (final a in added) a.toJson()],
        if (generator != null) 'generator': generator,
        'hostFiles': [for (final (f, _) in staged) f.path],
      },
    );
  }

  ({TestCardSpec? spec, StructuredResponse? error}) _cardSpec(Map<String, Object?> args, {required String kind, required int count}) {
    final size = args['size'] as String? ?? '1080x1920';
    final m = RegExp(r'^(\d+)\s*[xX]\s*(\d+)$').firstMatch(size.trim());
    if (m == null) return (spec: null, error: _bad('size must look like 1080x1920, got "$size"'));
    final spec = TestCardSpec(
      width: int.parse(m.group(1)!),
      height: int.parse(m.group(2)!),
      fps: argInt(args, 'fps') ?? 30,
      durationSec: argNum(args, 'durationSec') ?? 6,
      rotation: argInt(args, 'rotation') ?? 0,
      photo: kind == 'photo',
      photoCount: kind == 'photo' ? count : 1,
    );
    final problem = spec.problem;
    return problem == null ? (spec: spec, error: null) : (spec: null, error: _bad(problem));
  }

  Future<StructuredResponse> _clear(MediaDevice device, Gallery gallery, SeedLedger ledger, String? name, PhaseReporter phases) async {
    final all = ledger.load();
    final chosen = name == null ? all : [for (final a in all) if (a.name == name || a.name.startsWith('$name-') || a.file.startsWith('glint-${_safe(name)}.')) a];
    if (chosen.isEmpty) {
      return StructuredResponse(
        summary: all.isEmpty ? 'nothing to clear: glint has seeded nothing on ${device.id}' : 'nothing seeded as "$name" on ${device.id}',
        nextSteps: [if (all.isNotEmpty) 'seeded here: ${all.map((a) => a.name).join(', ')}'],
        data: {'device': device.id, 'removed': const <Object>[], 'remaining': [for (final a in all) a.name]},
      );
    }
    if (device.isIos) {
      return StructuredResponse.error(
        summary: 'the iOS simulator has no supported way to delete from Photos, so glint left ${chosen.length} seeded '
            'asset${chosen.length == 1 ? '' : 's'} in place',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'seeded as ${chosen.map((a) => a.file).join(', ')}',
        nextSteps: const [
          'delete them in the Photos app (their names start with glint-): attach in device mode and drive Photos, or ask the user',
          'or `xcrun simctl erase <udid>` when nothing else on that simulator matters (it wipes everything)',
        ],
      );
    }
    final failed = await phases.during('removing ${chosen.length} seeded asset${chosen.length == 1 ? '' : 's'}', () => gallery.remove(chosen));
    final removed = [for (final a in chosen) if (!failed.contains(a.file)) a];
    ledger.save([for (final a in all) if (!removed.contains(a)) a]);
    return StructuredResponse(
      summary: 'removed ${removed.length} seeded asset${removed.length == 1 ? '' : 's'} from ${device.id}: ${removed.map((a) => a.name).join(', ')}',
      warnings: [if (failed.isNotEmpty) 'could not remove ${failed.join(', ')}; they stay listed so a retry can finish'],
      data: {'device': device.id, 'removed': [for (final a in removed) a.toJson()], 'failed': failed},
    );
  }

  DateTime? _sinceTime(GlintSession session, String? since, List<StructuredResponse> failure) {
    if (since == null) return null;
    if (since == 'lastAction') {
      final last = session.actionLog.query(limit: 200).toList().reversed.where((e) => _actionTools.contains(e.tool)).firstOrNull;
      if (last == null) {
        failure.add(_bad('since:"lastAction" found no gesture or typing in this session',
            nextSteps: const ['run the action first, or pass an ISO time such as 2026-10-10T14:30:00']));
        return null;
      }
      return last.timestamp;
    }
    final parsed = DateTime.tryParse(since);
    if (parsed == null) {
      failure.add(_bad('since must be lastAction or an ISO time, got "$since"'));
    }
    return parsed;
  }

  String? _appId(GlintSession session, MediaDevice device, Map<String, Object?> args) {
    final given = args['appId'] as String?;
    if (given != null && given.isNotEmpty) return given;
    final app = session.active;
    if (app == null || app.id != device.id) return null;
    return app.bundleId;
  }

  Future<StructuredResponse> _files(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final failure = <StructuredResponse>[];
    final target = await _device(session, args, failure);
    if (target == null) return failure.single;
    final device = target;
    final appId = _appId(session, device, args);
    if (appId == null) {
      return _bad('no app to read files from: the attached app has no known ${device.isIos ? 'bundle id' : 'package'}',
          nextSteps: const ['pass appId:"<bundle id or package>"']);
    }
    final files = AppFiles(device, appId);
    if (argBool(args, 'pull') ?? false) {
      final path = args['path'] as String?;
      if (path == null || path.isEmpty) return _bad('pull needs path', nextSteps: const ['list files first with `media op:files`, then pass one path']);
      final host = await files.pull(path, phases: phases);
      return StructuredResponse(
        summary: 'pulled ${path.split('/').last} (${_humanSize(host.lengthSync())}) to ${host.path}',
        nextSteps: ['`media op:inspect path:"${host.path}"` reads it (ffprobe, frames, test card decode)'],
        data: {'hostPath': host.path, 'size': host.lengthSync(), 'from': path},
      );
    }
    final since = _sinceTime(session, args['since'] as String?, failure);
    if (failure.isNotEmpty) return failure.single;
    final cap = (argInt(args, 'limit') ?? 50).clamp(1, 200);
    final listing = await phases.during('listing $appId files', () => files.list(since: since, glob: args['glob'] as String?));
    final shown = listing.files.take(cap).toList();
    final hidden = listing.total - shown.length;
    final root = listing.roots.first;
    String relative(String p) => p.startsWith('$root/') ? p.substring(root.length + 1) : p;
    final lines = [
      for (final f in shown) '${_humanSize(f.sizeBytes).padLeft(8)}  ${f.modified.toLocal().toIso8601String().substring(11, 19)}  ${relative(f.path)}',
    ];
    final filter = [if (since != null) 'since ${args['since']}', if (args['glob'] != null) 'matching ${args['glob']}'].join(' ');
    return StructuredResponse(
      summary: [
        '${listing.total} file${listing.total == 1 ? '' : 's'} in $appId${filter.isEmpty ? '' : ' $filter'}, newest first'
            '${hidden > 0 ? ' (showing ${shown.length}, $hidden more: narrow with glob or since, or raise limit)' : ''}',
        if (lines.isNotEmpty) 'root: $root',
        ...lines,
      ].join('\n'),
      warnings: listing.notes,
      nextSteps: [
        if (shown.isNotEmpty) '`media op:inspect path:"${relative(shown.first.path)}"` reads the newest (device files are pulled for you)',
        if (shown.isEmpty && since != null) 'nothing new: the app may still be writing, or wrote elsewhere (drop since to list everything)',
      ],
      data: {
        'appId': appId,
        'roots': listing.roots,
        'total': listing.total,
        'files': [for (final f in shown) f.toJson()],
        if (hidden > 0) 'more': hidden,
      },
    );
  }

  Future<StructuredResponse> _inspect(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final requested = args['path'] as String?;
    if (requested == null || requested.isEmpty) {
      return _bad('inspect needs path', nextSteps: const ['pass a host file, or a path from `media op:files`']);
    }
    var path = requested;
    var pulled = false;
    if (!File(path).existsSync()) {
      final failure = <StructuredResponse>[];
      final target = await _device(session, args, failure);
      final appId = target == null ? null : _appId(session, target, args);
      if (target == null || appId == null) {
        return _bad('no file at $requested on the host, and no app to pull it from',
            nextSteps: const ['pass a host path, or attach to the app (or pass device: and appId:) so a device path can be pulled']);
      }
      final files = AppFiles(target, appId);
      final inPlace = await files.iosFile(requested);
      path = inPlace?.path ?? (await files.pull(requested, phases: phases)).path;
      pulled = inPlace == null;
    }
    final probe = await probeMedia(path);
    final showProbe = argBool(args, 'probe') ?? true;
    final loudness = showProbe && probe.hasAudio ? await phases.during('measuring loudness', () => measureLoudness(path)) : null;
    final card = await phases.during('looking for a glint test card', () => decodeTestCard(path, probe, phases: phases));

    final images = <String>[];
    final frameNotes = <String>[];
    final wanted = args['frames'] as List? ?? const [];
    if (wanted.length > _maxFramesReturned) {
      return _bad('at most $_maxFramesReturned frames per call, got ${wanted.length}');
    }
    final maxSize = argInt(args, 'maxSize') ?? session.config.screenshotMaxSize;
    final framesDir = mediaDir('frames');
    final stem = _safe(path.split('/').last);
    for (final raw in wanted) {
      final at = parseFrameAt(raw, probe.durationSec);
      if (at == null) {
        return _bad('frames entries are seconds or start | middle | end, got "$raw"');
      }
      final out = '$framesDir/$stem-${at.label}.png';
      final ok = await phases.during('extracting frame ${at.label}', () => extractFrame(path, at, out));
      final size = ok ? pngSize(out) : null;
      if (size == null) {
        frameNotes.add('${at.label}: no frame there');
        continue;
      }
      final sent = await prepareModelImage(out, width: size.$1, height: size.$2, maxSize: maxSize, format: session.config.screenshotFormat, quality: session.config.screenshotQuality);
      images.add(sent.path);
      frameNotes.add('${at.label}: ${sent.width}x${sent.height}');
    }

    final lines = [
      if (card != null) card.summary,
      if (showProbe) ..._probeLines(probe, loudness),
      if (frameNotes.isNotEmpty) 'frames: ${frameNotes.join(', ')}${images.isEmpty ? '' : ' (images attached in this order)'}',
      if (pulled) 'pulled from the device to $path',
    ];
    return StructuredResponse(
      summary: lines.join('\n'),
      nextSteps: [
        if (card == null && probe.hasVideo && wanted.isEmpty) 'frames:["start","middle","end"] returns pictures to look at',
        if (card != null && !card.stats.complete) 'frames were lost or repeated: the export re-timed or trimmed the video',
      ],
      imagePaths: images,
      data: {
        ...probe.toJson(),
        'hostPath': path,
        if (loudness != null) 'loudness': loudness.toJson(),
        if (card != null) 'testcard': card.toJson(),
        if (images.isNotEmpty) 'frameFiles': images,
      },
    );
  }

  List<String> _probeLines(MediaProbe p, Loudness? loud) {
    final shown = p.displayed;
    return [
      if (p.hasVideo)
        '${p.kind} ${p.videoCodec} ${p.width}x${p.height}${p.rotation == 0 || shown == null ? '' : ' stored, rotation ${p.rotation} (displays ${shown.w}x${shown.h})'}'
            '${p.durationSec == null ? '' : ' · ${p.durationSec!.toStringAsFixed(2)} s'}${p.kind == 'video' && p.fps != null ? ' · ${p.fps!.toStringAsFixed(p.fps == p.fps!.roundToDouble() ? 0 : 2)} fps' : ''}'
            '${p.bitrate == null || p.kind == 'photo' ? '' : ' · ${(p.bitrate! / 1000).round()} kb/s'} · ${_humanSize(p.sizeBytes)}',
      if (!p.hasVideo) 'audio file · ${p.durationSec?.toStringAsFixed(2) ?? '?'} s · ${_humanSize(p.sizeBytes)}',
      if (p.hasAudio)
        'audio ${p.audioCodec} ${p.audioChannels} ch ${p.audioSampleRate} Hz'
            '${loud?.integratedLufs == null ? '' : ' · ${loud!.integratedLufs!.toStringAsFixed(1)} LUFS'}'
            '${loud?.maxDb == null ? '' : ' · peak ${loud!.maxDb!.toStringAsFixed(1)} dB'}'
            '${loud?.meanDb == null ? '' : ' · mean ${loud!.meanDb!.toStringAsFixed(1)} dB'}',
    ];
  }
}
