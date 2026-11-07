import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:grpc/grpc.dart' show GrpcError;

import '../../../interaction.dart';
import '../../interaction/image_size.dart';
import '../../media/app_files.dart';
import '../../media/gallery.dart';
import '../../media/host_tools.dart';
import '../../media/media_generate.dart';
import '../../interaction/emulator_control.dart' show EmulatorControl, EmulatorInstance;
import '../../media/emulator_audio.dart';
import '../../media/emulator_camera.dart';
import '../../media/emulator_events.dart';
import '../../media/sim_calls.dart';
import '../../media/sim_camera.dart';
import '../../media/sim_speech.dart';
import '../../interaction/siminject.dart';
import '../../media/mic_audio.dart';
import '../../media/media_inspect.dart';
import '../../media/permissions.dart';
import '../../media/picker.dart';
import '../../perception/android_native_reader.dart';
import '../../perception/native_scene_reader.dart' show NativeReader;
import '../../perception/native_surface.dart';
import '../../perception/ocr_native_reader.dart';
import '../../perception/picker_cells.dart';
import '../../perception/runner_native_reader.dart';
import '../../media/seed_ledger.dart';
import '../../media/testcard_generator.dart';
import '../envelope.dart';
import 'media_broadcast.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

const _actionTools = {
  'tap',
  'long_press',
  'swipe',
  'drag',
  'scroll',
  'scroll_to_find',
  'type',
  'key',
  'hardware_button',
  'batch'
};
const _generators = {'testcard', 'speech', 'tone'};
const _maxFramesReturned = 6;

/// Whether the system picker is still up, gone, or could not be told.
enum _PickerState { open, closed, unknown }

/// One read of the picker: its state, the other surface now in front when it closed, and why it could not be read.
typedef _PickerRead = ({_PickerState state, NativeSurface? surface, String? problem});

/// `media` puts photos, videos and audio in the device gallery, lists and pulls what the app wrote, and inspects media files (a glint test card decodes to rotation, mirror, scale, frames and audio sync).
class MediaTool extends GlintTool {
  const MediaTool();

  @override
  bool changesDevice(Map<String, Object?> args) =>
      GlintTool.opChangesDevice(args, readOps: const {'files', 'inspect', 'listen'}, defaultOp: 'files');

  @override
  Tool get definition => Tool(
        name: 'media',
        description:
            'Media on the device. op: seed (add a photo, video or audio to the gallery from a host file or a generator: '
            'testcard, speech, tone; clear:true removes what glint seeded, Android only), files (what the app wrote, newest first; pull:true copies one to the host), '
            'inspect (ffprobe, loudness, frames as images; a glint testcard also decodes to rotation, mirror, scale, dropped frames, audio offset), '
            'pick (choose a photo or video in the open system picker: name, index or newest), '
            'permission (set camera, microphone or photos access for the app: grant, deny, reset, limited), '
            'listen (Android emulator: record what the app plays; stop:true returns a WAV with peak, loudness and silences), '
            'mic (Android: feed a tone, speech or audio file into the microphone of every app that records, for durationSec; stop:true reports who recorded it), '
            'event (Android emulator: rotate, light, proximity, SMS; calls on Android and iOS simulators: call rings, answerCall, declineCall, endCall; iOS also callkit, which lets an app\'s own CallKit calls ring with an Answer/Decline overlay; replies say synthetic:true; stop:true removes the stand-in), '
            'camera (iOS simulator or Android emulator: what the cameras see, an image, video, testcard or the Mac webcam; lens front, back or both; stop:true removes it; on iOS apps see it through AVFoundation and the system camera picker (image_picker) with no app change; Android needs setup:true once). '
            'speech (what the user says to an app that listens: iOS simulator, scripted partial and final SFSpeechRecognizer results with authorization granted, no app change; Android: the text is spoken once into the microphone; stop:true removes it; replies are synthetic). '
            'broadcast (iOS simulator: runs the app\'s ReplayKit broadcast upload extension; it gets broadcastStarted, video and app-audio sample buffers, broadcastFinished; action arm (catch the app\'s picker press) | start (default; answers a pending press) | pause | resume | status | stop; source screen (default) | testcard | file; audio tone (default) | none | file; replies label what is synthetic). '
            'Generators and inspect need ffmpeg. errorKind: invalidArgument, unsupportedToolchain, deviceGone, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
                description:
                    'seed | files | inspect | pick | permission | listen | mic | event | camera | broadcast | speech'),
            'extension': Schema.string(
                description:
                    'broadcast: bundle id of the upload extension. Default: the one the app\'s picker names, else the only one.'),
            'audio': Schema.string(
                description:
                    'broadcast: app audio to deliver, tone (440 Hz, hz sets it), none, or an audio file path. Default tone.'),
            'stop': Schema.bool(
                description:
                    'listen: end the recording and report it. mic: stop feeding and report what was fed. camera: remove the feed. event (iOS calls): end any call and remove the stand-in. broadcast: same as action:stop. speech: remove the stand-in (iOS) or stop the microphone feed (Android).'),
            'lens': Schema.string(description: 'camera (iOS): front | back | both. Default both.'),
            'fit': Schema.string(
                description:
                    'camera (iOS): contain (whole picture, black bars) | cover (fills the frame, crops). Default contain.'),
            'zoom': Schema.num(
                description:
                    'camera (iOS): size of the picture inside the frame, 0.1 to 1 (0.75 leaves a margin, as a card held a little back). Default 1.'),
            'force': Schema.bool(
                description:
                    'camera, broadcast (iOS): take it over from another glint that holds it (changes or stops its run).'),
            'relaunch': Schema.bool(
                description:
                    'camera, speech, event call, broadcast (iOS): restart an app that started before glint could load into it. Its state is lost.'),
            'setup': Schema.bool(
                description:
                    'camera: true lets glint feed the AVD cameras (one emulator restart), false restores them.'),
            'value': Schema.string(
                description:
                    'event rotate: portrait | landscape | reversePortrait | reverseLandscape | auto. light: lux. proximity: near | far.'),
            'number': Schema.string(
              description:
                  'event call, sms: the caller. Default 5551234. answerCall, declineCall, endCall: the number of the last call on that device (Android: the last one rung), else 5551234.',
            ),
            'permission': Schema.string(description: 'permission: camera | microphone | photos.'),
            'action': Schema.string(
                description:
                    'permission: grant | deny | reset (ask again) | limited (photos, Android 14+). broadcast: arm | start | pause | resume | status | stop. Default start.'),
            'device': Schema.string(description: 'Simulator UDID or adb serial. Default: the attached device.'),
            'kind': Schema.string(
                description:
                    'seed: photo | video | audio. Default: from source, else video. event: rotate | light | proximity | call | answerCall | declineCall | endCall | callkit (iOS) | sms.'),
            'source': Schema.string(
                description:
                    'seed: a host file path, or testcard | speech | tone. Default: testcard (tone for audio). camera: an image or video path, testcard, or webcam (iOS: the Mac camera, macOS asks once for access). broadcast: screen (default), testcard, or an image or video path. mic: tone (default), speech, or a host audio file.'),
            'name': Schema.string(
                description:
                    'seed: asset name (also the file name). clear:true with name removes just that one. pick: a seeded asset to choose.'),
            'index': Schema.int(description: 'pick: position in the picker, 0 = newest. Default 0.'),
            'count': Schema.int(description: 'seed testcard photo: how many photos. Default 1.'),
            'clear':
                Schema.bool(description: 'seed: remove what glint seeded on this device, nothing else. Android only.'),
            'size': Schema.string(
                description:
                    'testcard: WxH, even. Default 1080x1920. broadcast: delivered frame size, default the source size.'),
            'durationSec': Schema.num(
                description:
                    'testcard video or tone: seconds. Default 6. mic: how long the feed runs, up to 600. Default 60.'),
            'fps': Schema.int(
                description:
                    'testcard video: frames per second. Default 30. broadcast: frames delivered per second, 1 to 60, default 15.'),
            'rotation':
                Schema.int(description: 'testcard video: rotation tag 0 | 90 | 180 | 270 (clockwise). Default 0.'),
            'text': Schema.string(
                description:
                    'speech: what the user says. seed or mic with source speech: what to say. event sms: the message. event call (iOS): the caller name shown (default the number).'),
            'confidence':
                Schema.num(description: 'speech (iOS): confidence of the final result, 0 to 1. Default 0.92.'),
            'wordMs': Schema.int(
                description: 'speech (iOS): milliseconds between words, so between partial results. Default 280.'),
            'partials': Schema.bool(
                description: 'speech (iOS): send a partial result per word before the final. Default true.'),
            'finalMs': Schema.int(
                description:
                    'speech (iOS): pause after the last word before the final result, unless the app ends its audio first. Default 1200.'),
            'waitMs': Schema.int(
                description:
                    'speech (iOS): how long to wait for the app to start listening when it is not yet. Default 5000.'),
            'error': Schema.string(
                description:
                    'speech (iOS): instead of words, fail the listening task: ${simSpeechErrors.keys.join(' | ')}.'),
            'voice':
                Schema.string(description: 'speech (Android), seed and mic with source speech: a macOS voice name.'),
            'hz': Schema.num(description: 'tone: frequency. Default 440 (mic: 1000).'),
            'since':
                Schema.string(description: 'files: lastAction (since the last tap, type, swipe ...) or an ISO time.'),
            'glob':
                Schema.string(description: 'files: e.g. *.mp4 (matches the file name, or the path when it has a /).'),
            'limit': Schema.int(description: 'files: cap on the list. Default 50, max 200.'),
            'pull': Schema.bool(description: 'files: copy path to the host and return the host path.'),
            'path': Schema.string(description: 'files pull / inspect: a host path, or a path from files.'),
            'appId': Schema.string(description: 'files, permission: bundle id or package. Default: the attached app.'),
            'frames': Schema.list(
                description:
                    'inspect: times to return as images, seconds or start | middle | end (max $_maxFramesReturned).'),
            'probe':
                Schema.bool(description: 'inspect: false leaves out the metadata and loudness lines. Default true.'),
            'maxSize': Schema.int(
                description: 'inspect: longest side of returned frames (0 = full). Default: screenshotMaxSize.'),
          },
          required: ['op'],
        ),
      );

  @override
  Duration callCeiling(GlintSession session, Map<String, Object?> args) => const Duration(minutes: 11);

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
        'pick' => await _pick(session, args, phases),
        'permission' => await _permission(session, args),
        'listen' => await _listen(session, args),
        'mic' => await _mic(session, args, phases),
        'event' => await _event(session, args, phases),
        'camera' => await _camera(session, args, phases),
        'broadcast' => await _broadcast(session, args, phases),
        'speech' => await _speech(session, args, phases),
        _ => _bad(
            'op must be seed, files, inspect, pick, permission, listen, mic, event, camera, broadcast or speech, got ${op ?? 'nothing'}'),
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
        nextSteps: const [
          'pass a video, photo or audio file; for a file the app wrote, list it with `media op:files` first'
        ],
      );
    }
  }

  void Function(int, String)? _progressSink(GlintSession session, CallToolRequest request) {
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    if (token == null || notifier == null) return null;
    return (elapsedSec, phase) =>
        notifier(ProgressNotification(progressToken: token, progress: elapsedSec, message: '$phase (${elapsedSec}s)'));
  }

  StructuredResponse _bad(String summary, {String? detail, List<String> nextSteps = const []}) =>
      StructuredResponse.error(
          summary: summary, errorKind: GlintErrorKind.invalidArgument, detail: detail, nextSteps: nextSteps);

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

  Future<MediaDevice?> _device(
      GlintSession session, Map<String, Object?> args, List<StructuredResponse> failure) async {
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
    if (isPhysicalIosUdid(id)) {
      failure.add(StructuredResponse.notOnThisDevice(Ability.media, iphoneAbilities.gaps[Ability.media]!));
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

  String _humanSize(int bytes) =>
      bytes >= 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).toStringAsFixed(0)} KB';

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
    if (generator == 'testcard' && kind == 'audio') {
      return _bad('a testcard is a photo or video, not audio',
          nextSteps: const ['use kind:"video" or "photo", or source:"speech" | "tone" for audio']);
    }
    if ((generator == 'speech' || generator == 'tone') && kind != 'audio') {
      return _bad('$generator makes audio, not $kind', nextSteps: const ['use kind:"audio"']);
    }
    if (device.isIos && kind == 'audio') {
      return StructuredResponse.error(
        summary: 'an iOS simulator gallery takes photos and videos, not audio files',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'simctl addmedia rejects audio, and the Photos library holds none',
        nextSteps: const [
          'on Android, seed kind:"audio" lands in Music',
          'on iOS pass a video that carries the audio (kind:"video" with a host file)'
        ],
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
          if (text == null || text.trim().isEmpty) {
            return _bad('source speech needs text', nextSteps: const ['pass text:"what to say"']);
          }
          staged
              .add((await generateSpeech(text, 'glint-$base', voice: args['voice'] as String?, phases: phases), base));
        case 'tone':
          final duration = argNum(args, 'durationSec') ?? 6;
          if (duration <= 0 || duration > 600) {
            return _bad('durationSec must be above 0 and at most 600, got $duration');
          }
          staged.add((await generateTone(argNum(args, 'hz') ?? 440, duration, 'glint-$base', phases: phases), base));
        default:
          return _bad('unknown source: $rawSource',
              nextSteps: const ['use testcard | speech | tone, or a host file path']);
      }
    }

    final added = <SeededAsset>[];
    final all = [...ledger.load()];
    for (final (file, name) in staged) {
      file.setLastModifiedSync(DateTime.now());
      final asset = await phases.during(
          'adding ${file.uri.pathSegments.last} to the gallery', () => gallery.add(file, name: name, kind: kind!));
      added.add(asset);
      ledger.save(all..add(asset));
    }
    final where = device.isIos ? 'Photos library' : 'MediaStore';
    final first = added.first;
    return StructuredResponse(
      summary:
          'seeded ${added.length == 1 ? '${first.kind} "${first.name}" (${_humanSize(first.sizeBytes)})' : '${added.length} ${first.kind}s "${first.name}"..."${added.last.name}"'} '
          'into the ${device.id} $where${first.devicePath == null ? '' : ' at ${first.devicePath}'}',
      nextSteps: [
        if (device.isIos)
          'open the app\'s picker (the system photo picker: Choose from library); the seeded item is the newest one'
        else
          'open the app\'s picker (Photo Picker or Files); the seeded item is the newest one',
        if (kind == 'video' && generator == 'testcard')
          'after the app exports it, `media op:files since:lastAction` then `media op:inspect path:<file>` decodes the card',
        if (device.isIos)
          'to remove it later, delete the glint-${first.name} item in the Photos app (the simulator offers no delete)'
        else
          '`media op:seed clear:true` removes what glint seeded',
      ],
      data: {
        'device': device.id,
        'assets': [for (final a in added) a.toJson()],
        if (generator != null) 'generator': generator,
        'hostFiles': [for (final (f, _) in staged) f.path],
      },
    );
  }

  ({TestCardSpec? spec, StructuredResponse? error}) _cardSpec(Map<String, Object?> args,
      {required String kind, required int count}) {
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

  Future<StructuredResponse> _clear(
      MediaDevice device, Gallery gallery, SeedLedger ledger, String? name, PhaseReporter phases) async {
    final all = ledger.load();
    final chosen = name == null
        ? all
        : [
            for (final a in all)
              if (a.name == name || a.name.startsWith('$name-') || a.file.startsWith('glint-${_safe(name)}.')) a
          ];
    if (chosen.isEmpty) {
      return StructuredResponse(
        summary: all.isEmpty
            ? 'nothing to clear: glint has seeded nothing on ${device.id}'
            : 'nothing seeded as "$name" on ${device.id}',
        nextSteps: [if (all.isNotEmpty) 'seeded here: ${all.map((a) => a.name).join(', ')}'],
        data: {
          'device': device.id,
          'removed': const <Object>[],
          'remaining': [for (final a in all) a.name]
        },
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
    final failed = await phases.during(
        'removing ${chosen.length} seeded asset${chosen.length == 1 ? '' : 's'}', () => gallery.remove(chosen));
    final removed = [
      for (final a in chosen)
        if (!failed.contains(a.file)) a
    ];
    ledger.save([
      for (final a in all)
        if (!removed.contains(a)) a
    ]);
    return StructuredResponse(
      summary:
          'removed ${removed.length} seeded asset${removed.length == 1 ? '' : 's'} from ${device.id}: ${removed.map((a) => a.name).join(', ')}',
      warnings: [
        if (failed.isNotEmpty) 'could not remove ${failed.join(', ')}; they stay listed so a retry can finish'
      ],
      data: {
        'device': device.id,
        'removed': [for (final a in removed) a.toJson()],
        'failed': failed
      },
    );
  }

  Future<StructuredResponse> _pick(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
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
        detail:
            'the picker runs in its own process, and only the XCUITest runner can read it (still starting, failed, or iosNativeRunner is false)',
        nextSteps: const ['attach again with config iosNativeRunner true, open the picker again, then pick'],
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
          if (surface != null)
            'get_scene to see what the native surface shows; `media op:seed` adds photos to choose from',
        ],
      );
    }
    final name = args['name'] as String?;
    final int index;
    if (name != null) {
      final device = MediaDevice(session.device.platform, session.device.id);
      final seeded = SeedLedger(device.id).load();
      final asset = [
        for (final a in seeded)
          if (a.name == name || a.file == 'glint-${_safe(name)}.png' || a.file.startsWith('glint-${_safe(name)}.')) a
      ].lastOrNull;
      if (asset == null) {
        return _bad('nothing seeded as "$name" on ${device.id}', nextSteps: [
          if (seeded.isNotEmpty) 'seeded here: ${seeded.map((a) => a.name).join(', ')}',
          'or pick by index:<n> (0 = newest)'
        ]);
      }
      final window = device.isIos ? const Duration(minutes: 1) : const Duration(seconds: 3);
      final later =
          seeded.where((a) => a.addedAt.isAfter(asset.addedAt) && a.addedAt.difference(asset.addedAt) <= window).length;
      final found = cellForAsset(cells, asset.addedAt, laterInSameWindow: later);
      if (found == null) {
        return StructuredResponse.error(
          summary: 'no cell in the picker shows "$name" (seeded ${asset.addedAt.toIso8601String().substring(11, 19)})',
          errorKind: GlintErrorKind.targetNotFound,
          detail: 'the picker shows: ${cells.take(6).map((c) => c.label).join('; ')}',
          nextSteps: const [
            'scroll the picker or switch to its Photos tab, then pick again',
            'or pick by index:<n> (0 = newest)'
          ],
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
    final tapped = 'tapped "${cell.label}"${name == null ? ' (index $index)' : ' (seeded "$name")'}';
    final deadline = DateTime.now().add(_pickBudget);
    final settled = await phases.during('waiting for the picker after $tapped', () async {
      var read = await _awaitPicker(app, reader, deadline, stopAtConfirm: true);
      SurfaceChoice? confirm;
      if (read.state == _PickerState.open) {
        confirm = _confirmChoice(read.surface);
        if (confirm != null) {
          await session.backend.tap(physicalX: (confirm.x * dpr).round(), physicalY: (confirm.y * dpr).round());
          read = await _awaitPicker(app, reader, deadline, stopAtConfirm: false);
        }
      }
      return (read: read, confirmed: confirm?.text);
    });
    final read = settled.read;
    final confirmed = settled.confirmed;
    final done = '$tapped${confirmed == null ? '' : ', then $confirmed'}';
    final data = {
      'picked': cell.label,
      'index': index,
      if (confirmed != null) 'confirmed': confirmed,
      'pickerState': read.state.name,
      if (read.state != _PickerState.unknown) 'pickerClosed': read.state == _PickerState.closed,
    };
    if (read.state == _PickerState.unknown) {
      return StructuredResponse.error(
        summary: '$done, but glint cannot tell whether the picker closed or a photo was chosen',
        errorKind: GlintErrorKind.pickIncomplete,
        detail: read.problem ?? 'the native surface could not be read',
        nextSteps: const [
          'get_scene to see what is on screen now',
          'to close the picker without choosing, tap text:"Cancel" (or text:"Close") on it',
        ],
      ).mergeData(data);
    }
    if (read.state == _PickerState.open) {
      return StructuredResponse.error(
        summary: '$done, but the picker is still open: no photo was chosen',
        errorKind: GlintErrorKind.pickIncomplete,
        detail: 'after ${_pickBudget.inSeconds}s the surface in front is still the photo picker'
            '${confirmed == null ? ', and it shows no confirm button' : ' even after tapping $confirmed'}',
        nextSteps: const [
          'get_scene to see what the picker shows now',
          'media op:pick again (a different index:<n>), or tap the photo by its glintId from get_scene',
          'to close the picker without choosing, tap text:"Cancel" (or text:"Close") on it',
        ],
      ).mergeData(data);
    }
    final other = read.surface;
    return StructuredResponse(
      summary: '$done; the picker closed${other == null ? '' : ' and ${other.line} is now in front'}',
      warnings: [
        if (other != null) 'another surface took the place of the picker: ${other.line}',
      ],
      nextSteps: [
        if (other == null) 'get_scene to see the picked media in the app',
        if (other != null) 'get_scene, then handle the surface (tap its choice by text) before reading the pick',
      ],
      data: {...data, if (other != null) 'surface': other.toJson()},
    );
  }

  static const _pickBudget = Duration(seconds: 12);

  SurfaceChoice? _confirmChoice(NativeSurface? surface) =>
      surface?.choices.where((c) => pickerConfirmLabels.contains(c.text.toLowerCase())).firstOrNull;

  /// Re-reads the surface until the picker is gone, [deadline] passes, or (with [stopAtConfirm]) the picker offers a confirm button; an unreadable surface is never taken for a closed one.
  Future<_PickerRead> _awaitPicker(AppSession app, NativeReader reader, DateTime deadline,
      {required bool stopAtConfirm}) async {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final read = await _readPicker(app, reader);
      final settled = switch (read.state) {
        _PickerState.closed => true,
        _PickerState.open => stopAtConfirm && _confirmChoice(read.surface) != null,
        _PickerState.unknown => false,
      };
      if (settled || DateTime.now().isAfter(deadline)) return read;
    }
  }

  Future<_PickerRead> _readPicker(AppSession app, NativeReader reader) async {
    await app.refreshSceneMode();
    final problem = switch (reader) {
      RunnerNativeReader() => reader.lastReadProblem,
      AndroidNativeReader() => reader.lastFocusUnknown ? 'adb could not say which window has focus' : null,
      OcrNativeReader() => reader.lastReadProblem,
      _ => null,
    };
    if (problem != null) return (state: _PickerState.unknown, surface: null, problem: problem);
    final owner = app.nativeSurfaceName;
    if (owner == null) return (state: _PickerState.closed, surface: null, problem: null);
    final scene = await reader.readSnapshot();
    if (scene.root.glintId == '_native_surface') {
      final why = reader is AndroidNativeReader ? reader.lastReadProblem : null;
      return (state: _PickerState.unknown, surface: null, problem: why ?? 'the surface in front could not be read');
    }
    final surface = classifySurface(scene, owner: owner);
    if (surface.kind == SurfaceKind.picker) return (state: _PickerState.open, surface: surface, problem: null);
    if (surface.kind == SurfaceKind.unknown && !surface.hasContent) {
      return (
        state: _PickerState.unknown,
        surface: null,
        problem: 'the surface in front ($owner) shows nothing readable'
      );
    }
    return (state: _PickerState.closed, surface: surface, problem: null);
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
      return _bad(
          'no app to set $permission for: the attached app has no known ${device.isIos ? 'bundle id' : 'package'}',
          nextSteps: const ['pass appId:"<bundle id or package>"']);
    }
    try {
      final done = await setPermission(device, appId, permission!, action!);
      final verb = switch (action) {
        'grant' => 'granted',
        'deny' => 'denied',
        'reset' => 'reset (the app will ask again)',
        _ => 'set to limited'
      };
      return StructuredResponse(
        summary: '$permission $verb for $appId on ${device.id}',
        warnings: [if (done.caution != null) done.caution!],
        nextSteps: const ['get_scene, then drive the flow that uses it'],
        data: {
          'permission': permission,
          'action': action,
          'appId': appId,
          'device': device.id,
          'applied': done.applied
        },
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
        errorKind: e.unknownApp
            ? GlintErrorKind.targetNotFound
            : e.notDeclared
                ? GlintErrorKind.invalidArgument
                : GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [
          if (e.unknownApp) 'pass the installed package as appId',
          if (e.notDeclared) 'nothing to set: the app never asks for $permission, so it has no access either way',
          if (!e.unknownApp && !e.notDeclared) 'check the device is booted, then retry',
        ],
      );
    }
  }

  String _adbPath(GlintSession session) {
    final attached = session.isAttached ? session.device : null;
    return attached is AndroidDevice ? attached.adbPath : (resolveAdbPath(null) ?? 'adb');
  }

  Future<({EmulatorAudio? audio, StructuredResponse? error})> _emulatorAudio(
      GlintSession session, Map<String, Object?> args) async {
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
    if (audio != null) return (audio: audio, error: null);
    final emulator = await EmulatorInstance.locate(id, adbPath: _adbPath(session));
    return (
      audio: null,
      error: emulator == null
          ? StructuredResponse.error(
              summary: 'found no emulator behind $id',
              errorKind: GlintErrorKind.deviceGone,
              detail: 'neither a running record nor the emulator console answered for $id',
              nextSteps: const ['check the emulator is running (adb devices), then retry'],
            )
          : StructuredResponse.error(
              summary: 'cannot record $id: it has no gRPC control',
              errorKind: GlintErrorKind.unsupportedBackendAction,
              detail: emulator.noControlReason,
              nextSteps: emulator.controlSteps,
            ),
    );
  }

  Future<StructuredResponse> _listen(GlintSession session, Map<String, Object?> args) async {
    final found = await _emulatorAudio(session, args);
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
      return _bad('nothing is being recorded on ${audio.serial}',
          nextSteps: const ['start with `media op:listen`, play, then stop']);
    }
    final wav =
        writeWav('${mediaDir('pulled')}/${audio.serial}-speaker-${DateTime.now().millisecondsSinceEpoch}.wav', rec.pcm);
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

  /// Feeds audio into the microphone of every app that records on an Android device, through glint's device server (a loop-back audio policy, shell's own permission); stop:true ends it.
  Future<StructuredResponse> _mic(
    GlintSession session,
    Map<String, Object?> args,
    PhaseReporter phases, {
    bool once = false,
  }) async {
    final wanted = args['device'] as String?;
    final app = wanted == null ? session.active : session.apps.where((a) => a.device.id == wanted).firstOrNull;
    final dev = app?.device;
    if (dev is! AndroidDevice) {
      return StructuredResponse.error(
        summary: 'mic works on Android devices only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: dev != null && dev.platform == DevicePlatform.ios
            ? 'the iOS simulator records the Mac\'s own microphone, and nothing can feed it without a macOS permission'
            : wanted != null
                ? 'no attached device is $wanted'
                : 'attach to an Android device first',
        nextSteps: const ['run the voice flow on an Android emulator or phone'],
      );
    }
    final server = dev.server;
    if (server == null || !server.running) {
      return StructuredResponse.error(
        summary: 'the microphone feed needs glint\'s device server, which is not running on ${dev.serial}',
        errorKind: GlintErrorKind.backendToolError,
        detail:
            'the server feeds the microphone from inside Android; another automation tool may hold the accessibility connection it starts with',
        nextSteps: const ['stop other automation tools on the device, then attach again'],
      );
    }
    if (argBool(args, 'stop') ?? false) {
      final r = await server.call(const {'cmd': 'micStop'});
      final seconds = ((r['recordedMs'] as num?) ?? 0) / 1000;
      final who = [for (final p in (r['recordedBy'] as List? ?? const [])) '$p'];
      return StructuredResponse(
        summary: r['wasFeeding'] != true
            ? 'the microphone of ${dev.serial} was not being fed'
            : who.isEmpty
                ? 'stopped the microphone feed: no app recorded meanwhile'
                : 'stopped the microphone feed: ${who.join(', ')} recorded about ${seconds.toStringAsFixed(1)} s of it',
        data: {'device': dev.serial, 'recordedSeconds': seconds, 'recordedBy': who},
      );
    }
    final ({File pcm, String label}) audio;
    try {
      audio = await micAudio((args['source'] as String?) ?? 'tone',
          hz: argNum(args, 'hz')?.toDouble(),
          text: args['text'] as String?,
          voice: args['voice'] as String?,
          phases: phases);
    } on GalleryError catch (e) {
      return _bad(e.summary,
          nextSteps: [if (e.detail.isNotEmpty) e.detail, 'source: tone (hz), speech (text) or a host audio file']);
    }
    final audioMs = audio.pcm.lengthSync() * 1000 ~/ (micSampleRate * 2);
    final seconds = once ? audioMs / 1000 : (argNum(args, 'durationSec') ?? 60).clamp(1, 600);
    const remote = '/data/local/tmp/glint-mic.pcm';
    final push = await runBounded(
      dev.adbPath,
      ['-s', dev.serial, 'push', audio.pcm.path, remote],
      timeout: const Duration(seconds: 30),
      phase: 'adb push of the mic audio',
    );
    if (push.exitCode != 0) {
      return StructuredResponse.error(
          summary: 'could not push the audio to ${dev.serial}',
          errorKind: GlintErrorKind.backendToolError,
          detail: '${push.stderr}'.trim());
    }
    final r = await server.call({'cmd': 'micStart', 'path': remote, 'ms': once ? audioMs : (seconds * 1000).round()});
    if (r['ok'] != true) {
      return StructuredResponse.error(
        summary: 'Android refused the microphone feed',
        errorKind: GlintErrorKind.backendToolError,
        detail: '${r['error']}: ${r['detail']}',
        nextSteps: const ['check the device runs Android 10 or later'],
      );
    }
    return StructuredResponse(
      summary: once
          ? 'microphone of ${dev.serial} fed ${audio.label} once (${seconds.toStringAsFixed(1)} s): any app that records hears it'
          : 'microphone of ${dev.serial} fed for ${seconds.toStringAsFixed(0)} s: any app that records hears ${audio.label}, looped',
      warnings: const ['while the feed runs, apps hear only the feed, not the device\'s real microphone'],
      nextSteps: const [
        'make the app record, then `media op:mic stop:true` to see which app recorded it and for how long'
      ],
      data: {'device': dev.serial, 'source': audio.label, 'seconds': seconds},
    );
  }

  Future<StructuredResponse> _event(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final kind = args['kind'] as String?;
    if (!eventKinds.contains(kind)) return _bad('event needs kind: ${eventKinds.join(' | ')}');
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"emulator-5554"');
    if (simCallKinds.contains(kind)) {
      final simulator = MediaDevice.platformOf(id) == DevicePlatform.ios && await const SimControl().status(id) != null;
      if (simulator) return _simCall(session, id, kind!, args, phases);
      if (kind == 'callkit' || MediaDevice.platformOf(id) == DevicePlatform.ios || isPhysicalIosUdid(id)) {
        return _bad(
          '$kind works on an iOS simulator only',
          detail: id.startsWith('emulator-')
              ? 'an Android emulator has no CallKit; `kind:"call"`, `answerCall`, `declineCall` and `endCall` ring it with gsm'
              : isPhysicalIosUdid(id)
                  ? 'a physical iPhone takes real calls and has its own CallKit, so glint injects nothing there'
                  : '$id is not an iOS simulator on this Mac',
          nextSteps: const [
            'pass the UDID of an iOS simulator (attach lists them), or use an Android emulator for `kind:"call"`'
          ],
        );
      }
    }
    if (!id.startsWith('emulator-')) {
      return StructuredResponse.error(
        summary: 'events go to Android emulators only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: MediaDevice.platformOf(id) == DevicePlatform.ios
            ? 'the iOS simulator has no way to rotate, set sensors or text from outside; calls work there (kind call, answerCall, declineCall, endCall, callkit)'
            : 'a physical phone takes no injected sensor, call or SMS events',
        nextSteps: const ['run this flow on an Android emulator', 'or ask the user to do it on the device'],
      );
    }
    final device = MediaDevice(DevicePlatform.android, id,
        adbPath: session.isAttached && session.device is AndroidDevice
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

  Future<StructuredResponse?> _simBooted(String id) async {
    if (await const SimControl().isBooted(id)) return null;
    return StructuredResponse.error(
      summary: 'simulator $id is not booted',
      errorKind: GlintErrorKind.deviceGone,
      nextSteps: ['attach device:"$id" boots it', 'or xcrun simctl boot $id'],
    );
  }

  String _dormantLibraryNote(SimInjector injector) {
    final holding = [for (final a in injector.loaded()) a.bundleId];
    return holding.isEmpty
        ? 'no app holds the glint library'
        : '${holding.join(', ')} still holds the dormant glint library (nothing runs); restart it to unload it';
  }

  Future<StructuredResponse> _simCall(
    GlintSession session,
    String id,
    String kind,
    Map<String, Object?> args,
    PhaseReporter phases,
  ) async {
    final down = await _simBooted(id);
    if (down != null) return down;
    final injector = SimInjector(id, progress: phases);
    final calls = SimCalls(injector);
    final wasOn = calls.on;
    var enabledHere = false;
    Future<String> undo() async {
      if (!enabledHere) return '';
      enabledHere = false;
      await calls.stop();
      return 'glint turned the call stand-in on for this call and has turned it off again, so nothing is left running';
    }

    try {
      if (argBool(args, 'stop') == true) {
        final was = await calls.stop();
        final clean = _dormantLibraryNote(injector);
        return StructuredResponse(
          summary: was
              ? 'the call stand-in is off: any call ended, the overlay is gone and CallKit is the app\'s own again; $clean'
              : 'the call stand-in was already off; $clean',
          nextSteps: const ['`media op:event kind:"call"` rings the phone again'],
          data: {
            'device': id,
            'kind': kind,
            'synthetic': true,
            'stillLoaded': [for (final a in injector.loaded()) a.bundleId],
          },
        );
      }
      final before = wasOn ? calls.apps() : const <CallsApp>[];
      final primary = _appId(session, MediaDevice(DevicePlatform.ios, id), args);
      bool hasRinging(List<CallsApp> a) => a.any((x) => x.calls.any((c) => c.state == 'ringing'));
      int count(List<CallsApp> a, bool Function(SimCall) test) => a.fold(0, (n, x) => n + x.calls.where(test).length);
      List<CallsApp> front(List<CallsApp> a) {
        final named = a.where((x) => primary != null && x.bundleId == primary).toList();
        return named.isNotEmpty ? named : a.where((x) => x.foreground).toList();
      }

      bool hasLive(List<CallsApp> a) => a.any((x) => x.calls.isNotEmpty);
      final connectedBefore = count(front(before), (c) => c.state == 'connected');
      final ringingBefore = count(front(before), (c) => c.state == 'ringing');
      final liveBefore = count(front(before), (_) => true);
      bool overlayUp(List<CallsApp> a) => a.every((x) => x.overlay);
      InjectReport? report;
      if (kind == 'call' || kind == 'callkit') {
        if (kind == 'call' && before.any((a) => a.has('cellular', 'ringing') || a.has('cellular', 'connected'))) {
          return _bad(
            'a call is already in progress',
            detail: 'one call at a time, as on a phone',
            nextSteps: const ['`media op:event kind:"endCall"` hangs it up, then ring again'],
          );
        }
        await calls.enable();
        enabledHere = !wasOn;
        report = await injector.ensure(
          appId: primary,
          relaunch: argBool(args, 'relaunch') == true,
          module: 'calls',
        );
        if (report.waiting.isNotEmpty) {
          throw SimInjectFailure(
            GlintErrorKind.appNotResumed,
            'no app is running to take the call',
            '${report.waiting.join(', ')} is not running on $id',
            ['attach launch:"${report.waiting.first}", then repeat the call'],
          );
        }
      } else if (!wasOn) {
        return _bad(
          'no call to $kind',
          detail: 'the call stand-in is off, so no call is ringing',
          nextSteps: const ['`media op:event kind:"call"` rings the phone first'],
        );
      }
      final CallsOutcome outcome;
      switch (kind) {
        case 'call':
          outcome = await calls.send(
            'ring',
            number: (args['number'] as String?) ?? '5551234',
            name: args['text'] as String?,
            primary: primary,
            phases: phases,
            until: hasRinging,
            settle: overlayUp,
          );
        case 'callkit':
          outcome = await calls.reported(primary: primary, phases: phases);
        case 'answerCall':
          if (!hasRinging(before)) {
            return _bad(
              'no ringing call to answer',
              detail: hasLive(before) ? 'the call is already answered' : 'no call is ringing',
              nextSteps: const ['`media op:event kind:"call"` rings the phone, or an app reports a CallKit call'],
            );
          }
          outcome = await calls.send(
            'answer',
            primary: primary,
            phases: phases,
            until: (a) => count(a, (c) => c.state == 'connected') > connectedBefore,
          );
        case 'declineCall':
          if (!hasRinging(before)) {
            return _bad(
              'no ringing call to decline',
              detail: hasLive(before) ? 'the call is already answered, so `endCall` ends it' : 'no call is ringing',
              nextSteps: const ['`media op:event kind:"call"` rings the phone, or an app reports a CallKit call'],
            );
          }
          outcome = await calls.send(
            'decline',
            primary: primary,
            phases: phases,
            until: (a) => count(a, (c) => c.state == 'ringing') < ringingBefore,
          );
        default:
          if (!hasLive(before)) {
            return _bad(
              'no call to end',
              detail: 'no call is ringing or connected',
              nextSteps: const ['`media op:event kind:"call"` rings the phone'],
            );
          }
          outcome = await calls.send(
            'end',
            primary: primary,
            phases: phases,
            until: (a) => count(a, (_) => true) < liveBefore,
          );
      }
      if (!outcome.held) {
        final note = await undo();
        final saw = [for (final a in outcome.required) ...a.calls.map((c) => '${c.kind} ${c.state}')];
        return StructuredResponse.error(
          summary: switch (kind) {
            'call' => 'the call did not ring in the app in front',
            'answerCall' => 'the call was not answered',
            'declineCall' => 'the call was not declined',
            _ => 'the call did not end',
          },
          errorKind: GlintErrorKind.targetNeverReady,
          detail:
              'the app in front applied the command but reports ${saw.isEmpty ? 'no call' : saw.join(', ')}${note.isEmpty ? '' : '; $note'}',
          nextSteps: const [
            'get_scene to see the screen, then repeat the call',
            '`media op:event kind:"callkit" stop:true` clears the stand-in if it is stuck',
          ],
        );
      }
      return _callReply(id, kind, args, outcome, report);
    } on SimInjectFailure catch (e) {
      final note = await undo();
      return StructuredResponse.error(
        summary: e.message,
        errorKind: e.kind,
        detail: note.isEmpty ? e.detail : '${e.detail}; $note',
        nextSteps: e.nextSteps,
      );
    } on MissingHostTool catch (e) {
      await undo();
      return _missingTool(e, 'event');
    } on Object {
      await undo();
      rethrow;
    }
  }

  StructuredResponse _callReply(
    String id,
    String kind,
    Map<String, Object?> args,
    CallsOutcome outcome,
    InjectReport? report,
  ) {
    final apps = outcome.apps;
    final who = apps.map((a) => a.bundleId).join(', ');
    final observers = apps.fold<int>(0, (n, a) => n + a.observers);
    final providers = apps.fold<int>(0, (n, a) => n + a.providers);
    final live = [for (final a in apps) ...a.calls];
    final overlay = apps.any((a) => a.overlay);
    final interruption = kind == 'callkit'
        ? 'none'
        : apps.map((a) => a.interruption).firstWhere((i) => i != 'none', orElse: () => 'none');
    final delivered = [
      if (interruption != 'none') 'AVAudioSession interruption $interruption',
      if (observers > 0) 'CXCallObserver told ($observers)',
      if (overlay) 'Answer/Decline overlay on screen',
    ];
    final number = (args['number'] as String?) ?? '5551234';
    final summary = switch (kind) {
      'call' => 'a synthetic incoming call from $number is ringing in $who',
      'answerCall' => 'the synthetic call is answered in $who',
      'declineCall' => 'the call was declined in $who',
      'endCall' => 'the call ended in $who',
      _ =>
        'the call stand-in is on in $who: ${live.isEmpty ? 'no call yet' : live.map((c) => '${c.kind} ${c.state}').join(', ')}',
    };
    final ringing = live.any((c) => c.state == 'ringing');
    final linked = apps.any((a) => a.callkitLinked);
    final gaps = [
      if (kind == 'call' && linked && observers == 0) 'CXCallObserver',
      if (kind == 'callkit' && linked && providers == 0) 'CXProvider',
    ];
    final loadedFirst = report != null && (report.load == InjectLoad.launch || report.load == InjectLoad.relaunch);
    return StructuredResponse(
      summary: '$summary${delivered.isEmpty ? '' : ' (${delivered.join(', ')})'}. synthetic:true',
      warnings: [
        ...?report?.warnings,
        if (kind == 'call' || kind == 'callkit')
          'synthetic: there is no telephony on a simulator, so the audio session is not really taken from the app; an app that must stop its own audio has to do it on the interruption',
        if (apps.any((a) => a.observerPath == 'unavailable'))
          'CXCall has no usable private API on this iOS, so CXCallObservers were not told; the interruption and the overlay still work',
        if (gaps.isNotEmpty)
          loadedFirst
              ? 'the app made no ${gaps.join(' or ')} (glint loaded before it started), so nothing reached that API'
              : 'glint sees no ${gaps.join(' or ')} in the app: one made before glint loaded is not reachable; repeat with relaunch:true so glint loads before the app starts',
        if (kind == 'callkit' && report != null && !linked)
          'the app does not load CallKit, so there is nothing to stand in for',
        if (kind == 'call' && !overlay && apps.any((a) => !a.foreground))
          'the app is in the background: the overlay shows when it returns to the foreground',
        if (outcome.silent.isNotEmpty)
          'not reached (in the background or not answering): ${outcome.silent.join(', ')}; the command stays pending, so one that loads or resumes before the next command applies it',
      ],
      nextSteps: [
        if (ringing)
          'tap text:"Answer" or tap text:"Decline" in the overlay, or `kind:"answerCall"` / `kind:"declineCall"`',
        if (live.any((c) => c.state == 'connected')) 'tap text:"End call", or `kind:"endCall"`',
        if (live.isEmpty && kind != 'call')
          '`kind:"call"` rings the phone; `kind:"callkit" stop:true` removes the stand-in',
        'get_scene to see how the app reacted',
      ],
      data: {
        'device': id,
        'kind': kind,
        'synthetic': true,
        'delivered': {
          'interruption': interruption,
          'callObservers': observers,
          'callkitProviders': providers,
          'overlay': overlay,
        },
        'calls': [
          for (final c in live) {'kind': c.kind, 'name': c.name, 'state': c.state, if (c.onHold) 'onHold': true},
        ],
        'apps': [for (final a in apps) a.toJson()],
        if (outcome.silent.isNotEmpty) 'notReached': outcome.silent,
        if (report != null) 'injected': report.toJson(modules: const ['calls']),
      },
    );
  }

  Future<StructuredResponse> _broadcast(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"<simulator udid>"');
    final simulator = MediaDevice.platformOf(id) == DevicePlatform.ios && await const SimControl().status(id) != null;
    if (!simulator) {
      return StructuredResponse.error(
        summary: 'broadcast runs an iOS upload extension on a simulator only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: isPhysicalIosUdid(id)
            ? 'a physical iPhone has the real ReplayKit and replayd, so the app\'s own broadcast works there'
            : id.startsWith('emulator-')
                ? 'on Android, screen sharing is MediaProjection: `device op:privacy permission:screen-capture` answers its consent'
                : '$id is not an iOS simulator on this Mac',
        nextSteps: const ['pass the UDID of an iOS simulator (attach lists them)'],
      );
    }
    return mediaBroadcast(
      args,
      phases,
      id: id,
      appId: _appId(session, MediaDevice(DevicePlatform.ios, id), args),
      simBooted: _simBooted,
      dormantNote: _dormantLibraryNote,
    );
  }

  Future<StructuredResponse> _speech(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"<simulator udid>"');
    final simulator = MediaDevice.platformOf(id) == DevicePlatform.ios && await const SimControl().status(id) != null;
    if (!simulator && (MediaDevice.platformOf(id) == DevicePlatform.ios || isPhysicalIosUdid(id))) {
      return _bad(
        'speech works on an iOS simulator or an Android device only',
        detail: isPhysicalIosUdid(id)
            ? 'a physical iPhone has a real microphone and recognizer, so glint injects nothing there'
            : '$id is not an iOS simulator on this Mac',
        nextSteps: const ['pass the UDID of an iOS simulator (attach lists them), or use an Android emulator'],
      );
    }
    if (!simulator) {
      if (argBool(args, 'stop') == true) return _mic(session, {...args, 'device': id}, phases);
      final text = args['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        return _bad('speech needs text on Android',
            nextSteps: const ['`media op:speech text:"what the user says"` speaks it into the microphone']);
      }
      return _mic(session, {...args, 'device': id, 'source': 'speech'}, phases, once: true);
    }
    final down = await _simBooted(id);
    if (down != null) return down;
    final text = (args['text'] as String?)?.trim() ?? '';
    final error = args['error'] as String?;
    if (error != null && !simSpeechErrors.containsKey(error)) {
      return _bad('error must be ${simSpeechErrors.keys.join(', ')}, got "$error"');
    }
    if (error != null && text.isNotEmpty) return _bad('pass text or error, not both');
    final confidence = argNum(args, 'confidence') ?? 0.92;
    if (confidence < 0 || confidence > 1) return _bad('confidence must be between 0 and 1, got $confidence');
    final wordMs = argInt(args, 'wordMs') ?? 280;
    if (wordMs < 50 || wordMs > 5000) return _bad('wordMs must be between 50 and 5000, got $wordMs');
    final finalMs = argInt(args, 'finalMs') ?? 1200;
    if (finalMs < 0 || finalMs > 20000) return _bad('finalMs must be between 0 and 20000, got $finalMs');
    final waitMs = argInt(args, 'waitMs') ?? 5000;
    if (waitMs < 0 || waitMs > 60000) return _bad('waitMs must be between 0 and 60000, got $waitMs');
    final injector = SimInjector(id, progress: phases);
    final speech = SimSpeech(injector);
    final wasOn = speech.on;
    var enabledHere = false;
    Future<String> undo() async {
      if (!enabledHere) return '';
      enabledHere = false;
      await speech.stop();
      return 'glint turned the speech stand-in on for this call and has turned it off again, so nothing is left running';
    }

    try {
      if (argBool(args, 'stop') == true) {
        final was = await speech.stop();
        final clean = _dormantLibraryNote(injector);
        return StructuredResponse(
          summary: was
              ? 'the speech stand-in is off: listening tasks ended as cancelled, and speech permission and availability are the simulator\'s own again; $clean'
              : 'the speech stand-in was already off; $clean',
          nextSteps: const ['`media op:speech` turns it on again'],
          data: {
            'device': id,
            'synthetic': true,
            'stillLoaded': [for (final a in injector.loaded()) a.bundleId],
          },
        );
      }
      final primary = _appId(session, MediaDevice(DevicePlatform.ios, id), args);
      await speech.enable();
      enabledHere = !wasOn;
      final report = await injector.ensure(
        appId: primary,
        relaunch: argBool(args, 'relaunch') == true,
        module: 'speech',
      );
      final speaking = text.isNotEmpty || error != null;
      final target = primary ?? report.target;
      if (speaking && report.waiting.isEmpty && target == null && report.running.isNotEmpty) {
        throw SimInjectFailure(
          GlintErrorKind.unknownApp,
          'glint cannot tell which app should hear it',
          'running: ${report.running.join(', ')}; none reports being in front',
          ['repeat the call with appId:"${report.running.first}" (or the app that listens)', 'or attach the app first'],
        );
      }
      if (report.waiting.isNotEmpty && speaking) {
        throw SimInjectFailure(
          GlintErrorKind.appNotResumed,
          'no app is running to listen',
          '${report.waiting.join(', ')} is not running on $id',
          ['attach launch:"${report.waiting.first}", then repeat the call'],
        );
      }
      final late = report.load == InjectLoad.lateLoad
          ? 'the app was already running, so a permission it asked for earlier keeps the answer it got; a recognition task it starts from now on gets glint\'s results'
          : null;
      final loaded = report.load == InjectLoad.already ? 'already loaded' : report.load.name;
      if (!speaking) {
        enabledHere = false;
        return StructuredResponse(
          summary: 'the speech stand-in is on: speech and microphone permission are granted without a prompt and '
              'recognition is available; a recognition task the app starts gets what `text` says${report.waiting.isEmpty ? '' : '; start the app to load it'}. injected: speech, $loaded.',
          warnings: [if (late != null) late, ...report.warnings],
          nextSteps: [
            if (report.waiting.isNotEmpty)
              'launch ${report.waiting.first} (attach launch:"${report.waiting.first}"): it loads glint at start',
            'start listening in the app (tap its microphone button)',
            '`media op:speech text:"what the user says"` sends the words as partial then final results',
            '`media op:speech stop:true` turns it off',
          ],
          data: {
            'device': id,
            'synthetic': true,
            'injected': report.toJson(modules: const ['speech'])
          },
        );
      }
      final wordCount = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
      final partialsWanted = error == null && (argBool(args, 'partials') ?? true);
      final outcome = await speech.send(
        error != null
            ? {'do': 'fail', 'error': error}
            : {
                'do': 'say',
                'text': text,
                'confidence': confidence,
                'wordMs': wordMs,
                'finalMs': finalMs,
                'partials': partialsWanted,
              },
        primary: target,
        waitMs: waitMs,
        deliverySeconds: 2 + 0.3 + wordCount * wordMs / 1000 + finalMs / 1000,
        phases: phases,
      );
      final who = outcome.app.bundleId;
      if (!outcome.taken) {
        final note = await undo();
        return StructuredResponse.error(
          summary: 'no recognition task was listening in $who',
          errorKind: GlintErrorKind.targetNeverReady,
          detail:
              'no SFSpeechRecognizer task was running within ${(waitMs / 1000).toStringAsFixed(1)} s${note.isEmpty ? '' : '; $note'}',
          nextSteps: const [
            'start listening in the app (tap its microphone or listen button), then repeat the call',
            'or pass waitMs to wait longer for the app to start listening',
            'get_scene to see what the app shows',
          ],
        );
      }
      final runs = outcome.runs;
      final partials = runs.fold<int>(0, (n, r) => n + r.partials);
      final finals = runs.fold<int>(0, (n, r) => n + r.finals);
      final cancelled = runs.where((r) => r.failure == 'cancelled').toList();
      final failed = runs.where((r) => r.failure.isNotEmpty && r.failure != 'cancelled').toList();
      if (error == null && finals == 0 && (cancelled.isNotEmpty || outcome.stopped)) {
        final plural = partials == 1 ? '' : 's';
        return StructuredResponse.error(
          summary:
              'the recognition task of $who was cancelled after ${outcome.stopped ? 'at least ' : ''}$partials partial result$plural, before the final result',
          errorKind: GlintErrorKind.targetNeverReady,
          detail: outcome.stopped
              ? 'the speech stand-in was turned off while the words were delivered, which cancels the task'
              : 'the app cancelled the task, so the words were not delivered as a final result',
          nextSteps: const [
            'start listening in the app again, then repeat the call',
            'get_scene to see what the app shows',
          ],
        );
      }
      if (error == null && finals == 0 && failed.isNotEmpty) {
        return StructuredResponse.error(
          summary: 'the recognition task of $who ended with ${failed.first.failure} instead of a final result',
          errorKind: GlintErrorKind.targetNeverReady,
          detail: 'the app ended the task before the words became a final result',
          nextSteps: const ['start listening in the app again, then repeat the call'],
        );
      }
      if (!outcome.settled && partials == 0) {
        return StructuredResponse.error(
          summary: 'the words reached the recognition task of $who but no result arrived in the app',
          errorKind: GlintErrorKind.appUnresponsive,
          detail: 'the task took the utterance and had delivered no partial or final result when glint stopped waiting',
          nextSteps: const [
            'get_scene to see what the app shows; the results may still be on their way',
            'check the app is not frozen, then repeat the call',
          ],
        );
      }
      final delivered = finals > 0;
      final plural = partials == 1 ? '' : 's';
      final said = error != null
          ? 'failed the listening task of $who with ${simSpeechErrors[error]}'
          : delivered
              ? 'said "$text" to $who: $partials partial result$plural and the final result reached its recognition task'
              : 'said "$text" to $who: $partials partial result$plural reached its recognition task, the final result is still pending';
      return StructuredResponse(
        summary: '$said (synthetic). injected: speech, $loaded.',
        warnings: [
          if (late != null) late,
          ...report.warnings,
          if (error == null && !delivered)
            'the final result had not reached the app yet; get_scene shows what it did with the words',
          if (outcome.silent.isNotEmpty)
            '${outcome.silent.join(', ')} holds the library but is not the target or not in front, so it ignored the call',
        ],
        nextSteps: const [
          'get_scene to read what the app shows',
          '`media op:speech text:"..."` after the app listens again says something else',
          '`media op:speech stop:true` turns the stand-in off',
        ],
        data: {
          'device': id,
          'synthetic': true,
          'app': who,
          if (error != null) 'error': error else 'text': text,
          'delivered': {
            'tasks': runs.length,
            'partialResults': partials,
            'finalResults': finals,
            if (failed.isNotEmpty) 'failures': [for (final r in failed) r.failure],
            'finalReachedApp': delivered,
          },
          'grantedWithoutPrompt': {'speech': outcome.app.authRequests, 'microphone': outcome.app.micRequests},
          'microphone': {
            'synthetic': true,
            'engineStartsAnsweredByGlint': outcome.app.fakeEngineStarts,
            'engineStartsHandedToTheRealEngine': outcome.app.realEngineStarts,
          },
          'injected': report.toJson(modules: const ['speech']),
        },
      );
    } on SimInjectFailure catch (e) {
      final note = await undo();
      return StructuredResponse.error(
        summary: e.message,
        errorKind: e.kind,
        detail: note.isEmpty ? e.detail : '${e.detail}; $note',
        nextSteps: e.nextSteps,
      );
    } on Object {
      await undo();
      rethrow;
    }
  }

  Future<StructuredResponse> _camera(GlintSession session, Map<String, Object?> args, PhaseReporter phases) async {
    final id = (args['device'] as String?) ?? (session.isAttached ? session.device.id : null);
    if (id == null) return _bad('no device: attach first, or pass device:"emulator-5554"');
    if (MediaDevice.platformOf(id) == DevicePlatform.ios) return _simCamera(session, id, args, phases);
    if (!id.startsWith('emulator-')) {
      return StructuredResponse.error(
        summary: 'camera feeds work on simulators and emulators only',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: 'a physical phone films what is in front of it',
        nextSteps: const [
          'run the camera flow on an iOS simulator or an Android emulator',
          'or `media op:seed` a photo and pick it from the gallery instead'
        ],
      );
    }
    final emulator = await EmulatorInstance.locate(id, adbPath: _adbPath(session));
    final avdDir = emulator?.avdDir;
    final avdName = emulator?.avdName;
    if (emulator == null || avdDir == null || avdName == null) {
      return StructuredResponse.error(
        summary: 'could not find the AVD behind $id',
        errorKind: GlintErrorKind.targetNotFound,
        detail: 'neither a running record nor the emulator console of $id named its AVD',
        nextSteps: const ['check the emulator is running (adb devices), then retry'],
      );
    }
    final restart =
        emulator.grpc == null ? emulator.controlSteps : const ['restart the emulator once (close it, start it again)'];
    final cam = EmulatorCamera(avdDir: avdDir, avdName: avdName);
    final setup = argBool(args, 'stop') == true ? false : argBool(args, 'setup');
    if (setup == true) {
      final already = cam.configured('back') && cam.live('back');
      await phases.during('letting glint feed the $avdName cameras', cam.setup);
      return StructuredResponse(
        summary: already
            ? 'glint already feeds the $avdName cameras'
            : 'glint can now feed the $avdName cameras once the emulator restarts and picks this up',
        nextSteps: [
          if (!already) ...restart,
          if (!already)
            'after the restart, `media op:camera source:"testcard"` (or an image or video path) sets what the cameras see',
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
          ...restart,
          'then set the source',
        ],
      );
    }
    final grpc = emulator.grpc;
    if (grpc == null) {
      return StructuredResponse.error(
        summary: 'cannot feed the $avdName cameras: $id has no gRPC control',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        detail: emulator.noControlReason,
        nextSteps: emulator.controlSteps,
      );
    }
    final source = (args['source'] as String?) ?? 'testcard';
    final File file;
    final String label;
    if (source == 'testcard') {
      file = await generateTestCardVideo(
          const TestCardSpec(width: 720, height: 1280, durationSec: 10, fps: 30), 'glint-camera-testcard',
          phases: phases);
      label = 'the glint test card';
    } else {
      file = File(source);
      if (!file.existsSync()) {
        return _bad('camera source must be testcard or an image or video path; "$source" does not exist');
      }
      label = file.uri.pathSegments.last;
    }
    final control = EmulatorControl(grpc);
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

  Future<StructuredResponse> _simCamera(
      GlintSession session, String id, Map<String, Object?> args, PhaseReporter phases) async {
    final down = await _simBooted(id);
    if (down != null) return down;
    final lens = (args['lens'] as String?) ?? 'both';
    if (!simCameraLenses.contains(lens)) return _bad('lens must be front, back or both, got "$lens"');
    final fit = (args['fit'] as String?) ?? 'contain';
    if (fit != 'contain' && fit != 'cover') return _bad('fit must be contain or cover, got "$fit"');
    final zoom = argNum(args, 'zoom') ?? 1;
    if (zoom < 0.1 || zoom > 1) return _bad('zoom must be between 0.1 and 1, got $zoom');
    final injector = SimInjector(id, progress: phases);
    final camera = SimCamera(injector);
    final holder = camera.otherHolder();
    if (holder != null && argBool(args, 'force') == true) camera.takeOver();
    if (holder != null && argBool(args, 'force') != true) {
      return StructuredResponse.error(
        summary: 'another glint holds the camera of $id',
        errorKind: GlintErrorKind.deviceBusy,
        detail:
            'glint process ${holder.pid} has held it since ${holder.since.toIso8601String()}${holder.app == null || holder.app!.isEmpty ? '' : ' and shows ${holder.app}'}',
        nextSteps: const [
          'use another simulator for this feed',
          'or repeat the call with force:true to take the camera over (the other agent loses its feed)',
        ],
      );
    }
    try {
      if (argBool(args, 'stop') == true) {
        final was = await camera.stop();
        final clean = _dormantLibraryNote(injector);
        return StructuredResponse(
          summary: was
              ? 'the simulator cameras are off again; apps lose them the next time they look for a camera; $clean'
              : 'the simulator cameras were already off; $clean',
          nextSteps: const ['`media op:camera source:"<file>"` turns them on again'],
          data: {
            'device': id,
            'cameras': const <String, Object?>{},
            'stillLoaded': [for (final a in injector.loaded()) a.bundleId],
          },
        );
      }
      final source = (args['source'] as String?) ?? 'testcard';
      final LensFeed feed;
      if (source == 'webcam') {
        feed = (kind: 'webcam', path: camera.webcamFrames, label: 'the Mac camera', fit: fit, zoom: zoom);
      } else if (source == 'testcard') {
        final file = await generateTestCardVideo(
            const TestCardSpec(width: 720, height: 1280, durationSec: 10, fps: 30), 'glint-camera-testcard',
            phases: phases);
        feed = (kind: 'video', path: file.path, label: 'the glint test card', fit: fit, zoom: zoom);
      } else {
        final file = File(source);
        if (!file.existsSync()) {
          return _bad('camera source must be testcard, webcam or an image or video path; "$source" does not exist');
        }
        feed = (
          kind: isImagePath(file.path) ? 'image' : 'video',
          path: file.absolute.path,
          label: file.uri.pathSegments.last,
          fit: fit,
          zoom: zoom
        );
      }
      final appId = _appId(session, MediaDevice(DevicePlatform.ios, id), args);
      final previous = camera.current();
      await camera.feed(lens, feed);
      final InjectReport report;
      try {
        report = await injector.ensure(appId: appId, relaunch: argBool(args, 'relaunch') == true, module: 'camera');
        if (feed.kind == 'webcam') await camera.startWebcam(phases);
      } on Object {
        await camera.restore(previous);
        rethrow;
      }
      final cameras = camera.current();
      final shown = lens == 'both' ? 'both cameras show' : 'the $lens camera shows';
      final relaunched = report.relaunched.isEmpty ? '' : ' ${report.relaunched.join(', ')} was restarted to load it.';
      final waiting = report.waiting.isEmpty ? '' : '; start the app to see it';
      final loaded = report.load == InjectLoad.already ? 'already loaded' : report.load.name;
      return StructuredResponse(
        summary: '$shown ${feed.label} (${feed.fit})$waiting. injected: camera, $loaded.$relaunched',
        warnings: [
          if (report.load == InjectLoad.lateLoad)
            'the app was already running, so only a camera it opens from now on sees the feed; a list it read earlier stays empty until it asks again',
          ...report.warnings,
        ],
        nextSteps: [
          if (report.waiting.isNotEmpty)
            'launch ${report.waiting.join(', ')} (attach launch:"${report.waiting.first}"), then open its camera screen',
          if (report.relaunched.isNotEmpty) 'attach again: the app restarted',
          if (report.waiting.isEmpty && report.relaunched.isEmpty)
            'open the camera screen: the preview shows it already',
          'take the photo or record, then `media op:files since:"lastAction"`',
          '`media op:camera lens:"front" source:"<other file>"` changes one lens; `stop:true` removes the feed',
        ],
        data: {
          'device': id,
          'cameras': {
            for (final e in cameras.entries)
              e.key: {'kind': e.value.kind, 'source': e.value.label, 'fit': e.value.fit, 'zoom': e.value.zoom},
          },
          'injected': report.toJson(modules: const ['camera']),
        },
      );
    } on SimInjectFailure catch (e) {
      return StructuredResponse.error(summary: e.message, errorKind: e.kind, detail: e.detail, nextSteps: e.nextSteps);
    } on MissingHostTool catch (e) {
      return _missingTool(e, 'camera');
    }
  }

  DateTime? _sinceTime(GlintSession session, String? since, List<StructuredResponse> failure) {
    if (since == null) return null;
    if (since == 'lastAction') {
      final last =
          session.actionLog.query(limit: 200).toList().reversed.where((e) => _actionTools.contains(e.tool)).firstOrNull;
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
      if (path == null || path.isEmpty) {
        return _bad('pull needs path', nextSteps: const ['list files first with `media op:files`, then pass one path']);
      }
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
    final listing =
        await phases.during('listing $appId files', () => files.list(since: since, glob: args['glob'] as String?));
    final shown = listing.files.take(cap).toList();
    final hidden = listing.total - shown.length;
    final root = listing.roots.first;
    String relative(String p) => p.startsWith('$root/') ? p.substring(root.length + 1) : p;
    final lines = [
      for (final f in shown)
        '${_humanSize(f.sizeBytes).padLeft(8)}  ${f.modified.toLocal().toIso8601String().substring(11, 19)}  ${relative(f.path)}',
    ];
    final filter =
        [if (since != null) 'since ${args['since']}', if (args['glob'] != null) 'matching ${args['glob']}'].join(' ');
    return StructuredResponse(
      summary: [
        '${listing.total} file${listing.total == 1 ? '' : 's'} in $appId${filter.isEmpty ? '' : ' $filter'}, newest first'
            '${hidden > 0 ? ' (showing ${shown.length}, $hidden more: narrow with glob or since, or raise limit)' : ''}',
        if (lines.isNotEmpty) 'root: $root',
        ...lines,
      ].join('\n'),
      warnings: listing.notes,
      nextSteps: [
        if (shown.isNotEmpty)
          '`media op:inspect path:"${relative(shown.first.path)}"` reads the newest (device files are pulled for you)',
        if (shown.isEmpty && since != null)
          'nothing new: the app may still be writing, or wrote elsewhere (drop since to list everything)',
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
        return _bad('no file at $requested on the host, and no app to pull it from', nextSteps: const [
          'pass a host path, or attach to the app (or pass device: and appId:) so a device path can be pulled'
        ]);
      }
      final files = AppFiles(target, appId);
      final inPlace = await files.iosFile(requested);
      path = inPlace?.path ?? (await files.pull(requested, phases: phases)).path;
      pulled = inPlace == null;
    }
    final probe = await probeMedia(path);
    final showProbe = argBool(args, 'probe') ?? true;
    final loudness =
        showProbe && probe.hasAudio ? await phases.during('measuring loudness', () => measureLoudness(path)) : null;
    var card = await phases.during('looking for a glint test card', () => decodeTestCard(path, probe, phases: phases));
    String? barsNote;
    if (card == null) {
      final crop = await letterboxCrop(path, probe);
      final inner = crop == null ? null : await cropCopy(path, crop, photo: probe.kind == 'photo');
      if (inner != null) {
        card = await phases.during('looking for a test card inside black bars',
            () async => decodeTestCard(inner, await probeMedia(inner), phases: phases));
        if (card != null) {
          barsNote =
              'the card sits inside black bars (picture ${crop!.split(':').take(2).join('x')} at ${crop.split(':').skip(2).join(',')})';
        }
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
      final ok = await phases.during(
          'extracting frame ${at.label}', () => extractFrame(path, at, out, still: probe.kind == 'photo'));
      final size = ok ? pngSize(out) : null;
      if (size == null) {
        frameNotes.add('${at.label}: no frame there');
        continue;
      }
      final sent = await prepareModelImage(out,
          width: size.$1,
          height: size.$2,
          maxSize: maxSize,
          format: session.config.screenshotFormat,
          quality: session.config.screenshotQuality);
      images.add(sent.path);
      frameNotes.add('${at.label}: ${sent.width}x${sent.height}');
    }

    final lines = [
      if (card != null) card.summary,
      if (barsNote != null) barsNote,
      if (showProbe) ..._probeLines(probe, loudness),
      if (frameNotes.isNotEmpty)
        'frames: ${frameNotes.join(', ')}${images.isEmpty ? '' : ' (images attached in this order)'}',
      if (pulled) 'pulled from the device to $path',
    ];
    return StructuredResponse(
      summary: lines.join('\n'),
      nextSteps: [
        if (card == null && probe.hasVideo && wanted.isEmpty)
          'frames:["start","middle","end"] returns pictures to look at',
        if (card != null && !card.photo && !card.stats.complete)
          'frames were lost or repeated: the export re-timed or trimmed the video',
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
