import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:grpc/grpc.dart' show GrpcError;

import '../../../interaction.dart';
import '../../interaction/image_size.dart';
import '../../media/app_files.dart';
import '../../media/gallery.dart';
import '../../media/host_tools.dart';
import '../../media/media_generate.dart';
import '../../interaction/emulator_control.dart' show EmulatorControl, EmulatorEndpoint;
import '../../media/emulator_audio.dart';
import '../../media/emulator_camera.dart';
import '../../media/emulator_events.dart';
import '../../media/media_inspect.dart';
import '../../media/permissions.dart';
import '../../media/picker.dart';
import '../../perception/runner_native_reader.dart';
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
            'inspect (ffprobe, loudness, frames as images; a glint testcard also decodes to rotation, mirror, scale, dropped frames, audio offset), '
            'pick (choose a photo or video in the open system picker: name, index or newest), '
            'permission (set camera, microphone or photos access for the app: grant, deny, reset, limited), '
            'listen (Android emulator: record what the app plays; stop:true returns a WAV with peak, loudness and silences), '
            'event (Android emulator: rotate, light, proximity, incoming call, endCall, SMS), '
            'camera (Android emulator: what both cameras see now, an image, video or testcard; setup:true once). '
            'Generators and inspect need ffmpeg. errorKind: invalidArgument, unsupportedToolchain, deviceGone, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'seed | files | inspect | pick | permission | listen | event | camera'),
            'stop': Schema.bool(description: 'listen: end the recording and report it.'),
            'setup': Schema.bool(description: 'camera: true lets glint feed the AVD cameras (one emulator restart), false restores them.'),
            'value': Schema.string(description: 'event rotate: portrait | landscape | reversePortrait | reverseLandscape | auto. light: lux. proximity: near | far.'),
            'number': Schema.string(description: 'event call, endCall, sms: the caller. Default 5551234.'),
            'permission': Schema.string(description: 'permission: camera | microphone | photos.'),
            'action': Schema.string(description: 'permission: grant | deny | reset (ask again) | limited (photos, Android 14+).'),
            'device': Schema.string(description: 'Simulator UDID or adb serial. Default: the attached device.'),
            'kind': Schema.string(description: 'seed: photo | video | audio. Default: from source, else video. event: rotate | light | proximity | call | endCall | sms.'),
            'source': Schema.string(description: 'seed: a host file path, or testcard | speech | tone. Default: testcard (tone for audio). camera: an image or video path, or testcard.'),
            'name': Schema.string(description: 'seed: asset name (also the file name). clear:true with name removes just that one. pick: a seeded asset to choose.'),
            'index': Schema.int(description: 'pick: position in the picker, 0 = newest. Default 0.'),
            'count': Schema.int(description: 'seed testcard photo: how many photos. Default 1.'),
            'clear': Schema.bool(description: 'seed: remove what glint seeded on this device, nothing else. Android only.'),
            'size': Schema.string(description: 'testcard: WxH, even. Default 1080x1920.'),
            'durationSec': Schema.num(description: 'testcard video or tone: seconds. Default 6.'),
            'fps': Schema.int(description: 'testcard video: frames per second. Default 30.'),
            'rotation': Schema.int(description: 'testcard video: rotation tag 0 | 90 | 180 | 270 (clockwise). Default 0.'),
            'text': Schema.string(description: 'speech: what to say. event sms: the message.'),
            'voice': Schema.string(description: 'speech: a macOS voice name.'),
            'hz': Schema.num(description: 'tone: frequency. Default 440.'),
            'since': Schema.string(description: 'files: lastAction (since the last tap, type, swipe ...) or an ISO time.'),
            'glob': Schema.string(description: 'files: e.g. *.mp4 (matches the file name, or the path when it has a /).'),
            'limit': Schema.int(description: 'files: cap on the list. Default 50, max 200.'),
            'pull': Schema.bool(description: 'files: copy path to the host and return the host path.'),
            'path': Schema.string(description: 'files pull / inspect: a host path, or a path from files.'),
            'appId': Schema.string(description: 'files, permission: bundle id or package. Default: the attached app.'),
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
        'pick' => await _pick(session, args),
        'permission' => await _permission(session, args),
        'listen' => await _listen(session, args),
        'event' => await _event(session, args),
        'camera' => await _camera(session, args, phases),
        _ => _bad('op must be seed, files, inspect, pick, permission, listen, event or camera, got ${op ?? 'nothing'}'),
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
      file.setLastModifiedSync(DateTime.now());
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

  Future<StructuredResponse> _pick(GlintSession session, Map<String, Object?> args) async {
    final app = session.active;
    final reader = session.nativeReader;
    if (app == null) {
      return StructuredResponse.error(
        summary: 'attach first: pick reads the system picker over the attached app',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['attach'],
      );
    }
    if (reader == null || (session.device is IosSimulator && reader is! RunnerNativeReader)) {
      return StructuredResponse.error(
        summary: 'glint cannot read the iOS photo picker on this attach',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'the picker runs in its own process, and only the XCUITest runner can read it',
        nextSteps: const ['attach iosBackend:"xctest", open the picker again, then pick'],
      );
    }
    await app.refreshSceneMode();
    final surface = app.nativeSurfaceName;
    final cells = surface == null ? const <PickerCell>[] : pickerCells((await reader.readSnapshot()).root.children);
    if (cells.isEmpty) {
      return StructuredResponse.error(
        summary: surface == null ? 'no system picker is open' : 'no photos or videos in $surface',
        errorKind: GlintErrorKind.targetNotFound,
        nextSteps: [
          if (surface == null) "open the app's photo picker first (e.g. tap its Choose from library), then pick",
          if (surface != null) 'get_scene to see what the native surface shows; `media op:seed` adds photos to choose from',
        ],
      );
    }
    final name = args['name'] as String?;
    final int index;
    if (name != null) {
      final device = MediaDevice(session.device.platform, session.device.id);
      final seeded = SeedLedger(device.id).load();
      final asset = [for (final a in seeded) if (a.name == name || a.file == 'glint-${_safe(name)}.png' || a.file.startsWith('glint-${_safe(name)}.')) a].lastOrNull;
      if (asset == null) {
        return _bad('nothing seeded as "$name" on ${device.id}',
            nextSteps: [if (seeded.isNotEmpty) 'seeded here: ${seeded.map((a) => a.name).join(', ')}', 'or pick by index:<n> (0 = newest)']);
      }
      final window = device.isIos ? const Duration(minutes: 1) : const Duration(seconds: 3);
      final later = seeded.where((a) => a.addedAt.isAfter(asset.addedAt) && a.addedAt.difference(asset.addedAt) <= window).length;
      final found = cellForAsset(cells, asset.addedAt, laterInSameWindow: later);
      if (found == null) {
        return StructuredResponse.error(
          summary: 'no cell in the picker shows "$name" (seeded ${asset.addedAt.toIso8601String().substring(11, 19)})',
          errorKind: GlintErrorKind.targetNotFound,
          detail: 'the picker shows: ${cells.take(6).map((c) => c.label).join('; ')}',
          nextSteps: const ['scroll the picker or switch to its Photos tab, then pick again', 'or pick by index:<n> (0 = newest)'],
        );
      }
      index = found;
    } else {
      index = argInt(args, 'index') ?? 0;
      if (index < 0 || index >= cells.length) {
        return _bad('index must be 0 to ${cells.length - 1} (the picker shows ${cells.length})');
      }
    }
    final cell = cells[index];
    final dpr = session.device.devicePixelRatio;
    await session.backend.tap(physicalX: (cell.x * dpr).round(), physicalY: (cell.y * dpr).round());
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await app.refreshSceneMode();
    String? confirmed;
    if (app.nativeSurfaceName != null) {
      final confirm = (await reader.readSnapshot())
          .root
          .children
          .where((n) => n.isNativeEnabled == true && n.axFrame != null && RegExp(r'^(Add|Done|Select|Choose|Open)$').hasMatch(n.textPreview ?? ''))
          .firstOrNull;
      if (confirm != null) {
        final f = confirm.axFrame!;
        await session.backend.tap(physicalX: ((f.x + f.w / 2) * dpr).round(), physicalY: ((f.y + f.h / 2) * dpr).round());
        confirmed = confirm.textPreview;
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await app.refreshSceneMode();
      }
    }
    final closed = app.nativeSurfaceName == null;
    return StructuredResponse(
      summary: 'picked "${cell.label}"${name == null ? ' (index $index)' : ' (seeded "$name")'}'
          '${confirmed == null ? '' : ', then tapped $confirmed'}'
          '${closed ? '; the picker closed' : '; the picker is still open'}',
      warnings: [if (!closed) 'the picker did not close: it may want more taps (a multi-select Add, or a crop step)'],
      nextSteps: [
        if (closed) 'get_scene to see the picked media in the app',
        if (!closed) 'get_scene to see the picker, then tap its confirm button',
      ],
      data: {'picked': cell.label, 'index': index, if (confirmed != null) 'confirmed': confirmed, 'pickerClosed': closed},
    );
  }

  Future<StructuredResponse> _permission(GlintSession session, Map<String, Object?> args) async {
    final permission = args['permission'] as String?;
    final action = args['action'] as String?;
    if (!permissionNames.contains(permission) || !permissionActions.contains(action)) {
      return _bad('unknown permission or action', detail: permissionUsage());
    }
    final failure = <StructuredResponse>[];
    final device = await _device(session, args, failure);
    if (device == null) return failure.single;
    final appId = _appId(session, device, args);
    if (appId == null) {
      return _bad('no app to set $permission for: the attached app has no known ${device.isIos ? 'bundle id' : 'package'}',
          nextSteps: const ['pass appId:"<bundle id or package>"']);
    }
    try {
      final done = await setPermission(device, appId, permission!, action!);
      final verb = switch (action) { 'grant' => 'granted', 'deny' => 'denied', 'reset' => 'reset (the app will ask again)', _ => 'set to limited' };
      return StructuredResponse(
        summary: '$permission $verb for $appId on ${device.id}',
        warnings: [if (done.caution != null) done.caution!],
        nextSteps: const ['get_scene, then drive the flow that uses it'],
        data: {'permission': permission, 'action': action, 'appId': appId, 'device': device.id, 'applied': done.applied},
      );
    } on PermissionUnsupported catch (e) {
      return StructuredResponse.error(
        summary: 'cannot set $permission to $action here: ${e.reason}',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        nextSteps: e.nextSteps,
      );
    } on PermissionRefused catch (e) {
      return StructuredResponse.error(
        summary: e.unknownApp
            ? '$appId is not installed on ${device.id}'
            : e.notDeclared
                ? '$appId does not declare the $permission permission, so the system cannot ${action == 'limited' ? 'limit' : action} it'
                : 'the device refused to ${action == 'limited' ? 'limit' : action} $permission for $appId',
        errorKind: e.unknownApp ? GlintErrorKind.targetNotFound : e.notDeclared ? GlintErrorKind.invalidArgument : GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [
          if (e.unknownApp) 'pass the installed package as appId',
          if (e.notDeclared) 'nothing to set: the app never asks for $permission, so it has no access either way',
          if (!e.unknownApp && !e.notDeclared) 'check the device is booted, then retry',
        ],
      );
    }
  }

  ({EmulatorAudio? audio, StructuredResponse? error}) _emulatorAudio(GlintSession session, Map<String, Object?> args) {
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return (audio: null, error: _bad('no device: attach first, or pass device:"emulator-5554"'));
    if (!id.startsWith('emulator-')) {
      return (
        audio: null,
        error: StructuredResponse.error(
          summary: 'listen works on Android emulators only',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          detail: MediaDevice.platformOf(id) == DevicePlatform.ios
              ? 'the iOS simulator plays through the Mac and offers no way to record one app from outside'
              : 'a physical phone offers no audio capture',
          nextSteps: const ['run the audio flow on an Android emulator', 'or ask the user to speak or listen'],
        ),
      );
    }
    final audio = EmulatorAudio.forSerial(id);
    if (audio == null) {
      return (
        audio: null,
        error: StructuredResponse.error(
          summary: 'found no control endpoint for $id',
          errorKind: GlintErrorKind.targetNotFound,
          detail: 'every emulator writes its gRPC port and token to the AVD running directory; none named $id',
          nextSteps: const ['check the emulator is running (adb devices), then retry'],
        ),
      );
    }
    return (audio: audio, error: null);
  }

  Future<StructuredResponse> _listen(GlintSession session, Map<String, Object?> args) async {
    final found = _emulatorAudio(session, args);
    final audio = found.audio;
    if (audio == null) return found.error!;
    if (!(argBool(args, 'stop') ?? false)) {
      audio.startCapture();
      return StructuredResponse(
        summary: 'listening to what ${audio.serial} plays',
        nextSteps: const ['make the app play (tap play), then `media op:listen stop:true` for the recording'],
        data: {'device': audio.serial},
      );
    }
    final rec = await audio.stopCapture();
    if (rec == null) {
      return _bad('nothing is being recorded on ${audio.serial}', nextSteps: const ['start with `media op:listen`, play, then stop']);
    }
    final wav = writeWav('${mediaDir('pulled')}/${audio.serial}-speaker-${DateTime.now().millisecondsSinceEpoch}.wav', rec.pcm);
    final stats = audioStats(rec.pcm);
    final quiet = stats.silences.fold(Duration.zero, (sum, s) => sum + (s.$2 - s.$1));
    final secs = rec.length.inMilliseconds / 1000;
    final heard = (rec.length - quiet).inMilliseconds / 1000;
    String at(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);
    return StructuredResponse(
      summary: heard <= 0.05
          ? 'silent: nothing played during ${secs.toStringAsFixed(1)} s'
          : 'sound for ${heard.toStringAsFixed(1)} of ${secs.toStringAsFixed(1)} s, peak ${stats.peakDb.toStringAsFixed(1)} dBFS, '
              'average ${stats.rmsDb.toStringAsFixed(1)} dBFS',
      nextSteps: ['`media op:inspect path:"${wav.path}"` for loudness and more'],
      data: {
        'device': audio.serial,
        'wav': wav.path,
        'seconds': secs,
        'soundSeconds': heard,
        'peakDb': stats.peakDb,
        'rmsDb': stats.rmsDb,
        'silences': [for (final (a, b) in stats.silences) '${at(a)}-${at(b)} s'],
      },
    );
  }

  Future<StructuredResponse> _event(GlintSession session, Map<String, Object?> args) async {
    final kind = args['kind'] as String?;
    if (!eventKinds.contains(kind)) return _bad('event needs kind: ${eventKinds.join(' | ')}');
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"emulator-5554"');
    if (!id.startsWith('emulator-')) {
      return StructuredResponse.error(
        summary: 'events go to Android emulators only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: MediaDevice.platformOf(id) == DevicePlatform.ios
            ? 'the iOS simulator has no way to rotate, set sensors, ring or text from outside'
            : 'a physical phone takes no injected sensor, call or SMS events',
        nextSteps: const ['run this flow on an Android emulator', 'or ask the user to do it on the device'],
      );
    }
    final device = MediaDevice(DevicePlatform.android, id, adbPath: session.isAttached && session.device is AndroidDevice
        ? (session.device as AndroidDevice).adbPath
        : resolveAdbPath(null) ?? 'adb');
    try {
      final said = await sendEvent(device, kind!,
          value: args['value']?.toString(), number: args['number'] as String?, text: args['text'] as String?);
      return StructuredResponse(
        summary: said,
        nextSteps: const ['get_scene to see how the app reacted'],
        data: {'device': id, 'kind': kind, if (args['value'] != null) 'value': args['value']},
      );
    } on EventFailed catch (e) {
      return StructuredResponse.error(
        summary: e.summary,
        errorKind: e.invalid ? GlintErrorKind.invalidArgument : GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [if (!e.invalid) 'check the emulator is running (adb devices), then retry'],
      );
    }
  }

  Future<StructuredResponse> _camera(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"emulator-5554"');
    if (!id.startsWith('emulator-')) {
      return StructuredResponse.error(
        summary: 'camera feeds work on Android emulators only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: MediaDevice.platformOf(id) == DevicePlatform.ios
            ? 'the iOS simulator has no camera at all'
            : 'a physical phone films what is in front of it',
        nextSteps: const ['run the camera flow on an Android emulator', 'or `media op:seed` a photo and pick it from the gallery instead'],
      );
    }
    final endpoint = EmulatorEndpoint.find(id);
    final avdDir = endpoint?.avdDir;
    final avdName = endpoint?.avdName;
    if (avdDir == null || avdName == null) {
      return StructuredResponse.error(
        summary: 'could not find the AVD behind $id',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'every emulator records its AVD folder in the AVD running directory; none named $id',
        nextSteps: const ['check the emulator is running (adb devices), then retry'],
      );
    }
    final cam = EmulatorCamera(avdDir: avdDir, avdName: avdName);
    final setup = argBool(args, 'setup');
    if (setup == true) {
      final already = cam.configured('back') && cam.live('back');
      await phases.during('letting glint feed the $avdName cameras', cam.setup);
      return StructuredResponse(
        summary: already
            ? 'glint already feeds the $avdName cameras'
            : 'glint can now feed the $avdName cameras; restart the emulator once (close it, start it again) so it picks this up',
        nextSteps: [
          if (!already) 'after the restart, `media op:camera source:"testcard"` (or an image or video path) sets what the cameras see',
          '`media op:camera setup:false` puts the original cameras back',
        ],
        data: {'device': id, 'avd': avdName, 'live': already},
      );
    }
    if (setup == false) {
      final undone = cam.undo();
      return StructuredResponse(
        summary: undone
            ? 'restored the original $avdName cameras; restart the emulator once for them to apply'
            : 'nothing to undo: glint never changed the $avdName cameras',
        data: {'device': id, 'avd': avdName, 'undone': undone},
      );
    }
    if (!cam.configured('back') || !cam.live('back')) {
      return StructuredResponse.error(
        summary: cam.configured('back')
            ? 'the emulator was started before glint could feed its cameras'
            : 'glint cannot feed the $avdName cameras yet',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'an emulator camera only takes a live feed in environment mode, which it reads at launch',
        nextSteps: [
          if (!cam.configured('back')) '`media op:camera setup:true` once',
          'restart the emulator once (close it, start it again), then set the source',
        ],
      );
    }
    final source = (args['source'] as String?) ?? 'testcard';
    final File file;
    final String label;
    if (source == 'testcard') {
      file = await generateTestCardVideo(const TestCardSpec(width: 720, height: 1280, durationSec: 10, fps: 30), 'glint-camera-testcard', phases: phases);
      label = 'the glint test card';
    } else {
      file = File(source);
      if (!file.existsSync()) return _bad('camera source must be testcard or an image or video path; "$source" does not exist');
      label = file.uri.pathSegments.last;
    }
    final control = EmulatorControl(endpoint!);
    try {
      final fed = await phases.during('fitting $label for the camera', () => cam.feed(file, control));
      return StructuredResponse(
        summary: 'both cameras now show $label, fitted whole into what an app sees',
        nextSteps: const [
          'the app\'s camera preview shows it already; take the photo or record, then `media op:files since:"lastAction"`',
          '`media op:inspect` on the result decodes a test card',
        ],
        data: {'device': id, 'source': label, 'feed': fed},
      );
    } on GrpcError catch (e) {
      return StructuredResponse.error(
        summary: 'the emulator refused the camera source',
        errorKind: GlintErrorKind.backendToolError,
        detail: '${e.message}',
        nextSteps: const ['restart the emulator once so it loads its environment, then retry'],
      );
    } finally {
      await control.close();
    }
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
    var card = await phases.during('looking for a glint test card', () => decodeTestCard(path, probe, phases: phases));
    String? barsNote;
    if (card == null) {
      final crop = await letterboxCrop(path, probe);
      final inner = crop == null ? null : await cropCopy(path, crop, photo: probe.kind == 'photo');
      if (inner != null) {
        card = await phases.during('looking for a test card inside black bars', () async => decodeTestCard(inner, await probeMedia(inner), phases: phases));
        if (card != null) barsNote = 'the card sits inside black bars (picture ${crop!.split(':').take(2).join('x')} at ${crop.split(':').skip(2).join(',')})';
        File(inner).deleteSync();
      }
    }

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
      final ok = await phases.during('extracting frame ${at.label}', () => extractFrame(path, at, out, still: probe.kind == 'photo'));
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
      if (barsNote != null) barsNote,
      if (showProbe) ..._probeLines(probe, loudness),
      if (frameNotes.isNotEmpty) 'frames: ${frameNotes.join(', ')}${images.isEmpty ? '' : ' (images attached in this order)'}',
      if (pulled) 'pulled from the device to $path',
    ];
    return StructuredResponse(
      summary: lines.join('\n'),
      nextSteps: [
        if (card == null && probe.hasVideo && wanted.isEmpty) 'frames:["start","middle","end"] returns pictures to look at',
        if (card != null && !card.photo && !card.stats.complete) 'frames were lost or repeated: the export re-timed or trimmed the video',
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
