import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glint_core/glint_core.dart' show HelperLife, ProcessRegistry;

import '../interaction/bounded_process.dart';
import '../interaction/device_claims.dart';
import '../interaction/result.dart';
import '../interaction/shipped_files.dart';
import '../interaction/siminject.dart';
import '../interaction/swift_helper.dart';
import '../observability/call_progress.dart';
import 'host_tools.dart';

const _imagePattern = r'\.(png|jpe?g|webp|heic|bmp|gif)$';
const _webcamSource = 'native/ios_sim_inject/mac/webcam.swift';
const _moduleName = 'camera';

/// The lenses a feed can name.
const simCameraLenses = {'front', 'back', 'both'};

/// Whether [path] is a still image rather than a video.
bool isImagePath(String path) => RegExp(_imagePattern, caseSensitive: false).hasMatch(path);

/// What one lens shows: an image, a video or the Mac camera, fitted `contain` (whole picture) or `cover` (fills the frame), at `zoom` (1 = fitted, 0.75 = three quarters of that, leaving a margin).
typedef LensFeed = ({String kind, String path, String label, String fit, double zoom});

/// The protocol the Mac camera helper must report; a different one is refused.
const int webcamProtocol = 1;

/// glint's camera for an iOS simulator: front and back cameras that apps read through AVFoundation, fed an image, a video or the Mac camera, through the injected library's `camera` module.
class SimCamera {
  SimCamera(this.injector);

  final SimInjector injector;

  /// The frame file the Mac camera helper writes and the library reads.
  String get webcamFrames => _frames;

  String get _frames => '${injector.controlDir}/webcam.frames';

  DeviceClaims get _claims => DeviceClaims(dir: '${injector.controlDir}/claims');

  /// What each lens shows now (`front`, `back`), or empty when the camera is off.
  Map<String, LensFeed> current() {
    final config = injector.moduleConfig(_moduleName);
    if (config == null) return const {};
    return {
      for (final lens in const ['front', 'back'])
        if (config[lens] is Map)
          lens: (
            kind: (config[lens] as Map)['kind'] as String,
            path: (config[lens] as Map)['path'] as String,
            label: ((config[lens] as Map)['label'] as String?) ?? '',
            fit: ((config[lens] as Map)['fit'] as String?) ?? 'contain',
            zoom: ((config[lens] as Map)['zoom'] as num?)?.toDouble() ?? 1,
          ),
    };
  }

  /// The glint process holding this camera if another live one does, else null.
  DeviceClaim? otherHolder() => _claims.heldByOther(injector.udid);

  /// Takes the camera over from whoever holds it.
  void takeOver() {
    final file = File('${injector.controlDir}/claims/${injector.udid}.json');
    if (file.existsSync()) file.deleteSync();
  }

  void _claim(String showing) {
    injector.prepareControlDir();
    _claims.claim(injector.udid, app: showing);
  }

  /// Shows [feed] in the lenses [lens] names, keeping what the other lens shows.
  Future<Map<String, LensFeed>> feed(String lens, LensFeed feed) async {
    final next = {...current()};
    for (final l in lens == 'both' ? const ['front', 'back'] : [lens]) {
      next[l] = feed;
    }
    await _write(next);
    return next;
  }

  /// Puts back what the lenses showed before a failed attempt.
  Future<void> restore(Map<String, LensFeed> previous) async {
    if (previous.isEmpty) {
      await stop();
    } else {
      await _write(previous);
    }
  }

  Future<void> _write(Map<String, LensFeed> lenses) async {
    _claim(lenses.values.map((f) => f.label).toSet().join(', '));
    await injector.setModule(_moduleName, {
      for (final e in lenses.entries)
        e.key: {
          'kind': e.value.kind,
          'path': e.value.path,
          'label': e.value.label,
          'fit': e.value.fit,
          'zoom': e.value.zoom,
        },
    });
    if (!lenses.values.any((f) => f.kind == 'webcam')) await stopWebcam();
  }

  /// Turns the camera off and removes what glint left for it; true when something was on.
  Future<bool> stop() async {
    final was = current().isNotEmpty;
    await injector.setModule(_moduleName, null);
    await stopWebcam();
    final commands = File('${injector.controlDir}/commands/$_moduleName.json');
    if (commands.existsSync()) commands.deleteSync();
    _claims.release(injector.udid);
    if (injector.activeModules().isEmpty) await injector.clearLaunchEnv();
    return was;
  }

  /// Starts the Mac camera pump and returns the frame file the library reads; asks macOS for camera access when it was never asked.
  Future<String> startWebcam(PhaseReporter? phases) async {
    final helper = await _webcamHelper(phases);
    final status = await runBounded(helper, ['--status'],
        timeout: const Duration(seconds: 30), phase: 'checking Mac camera access');
    final statusText = '${status.stdout}'.trim();
    final state = statusText.split(' ').first;
    if (state == 'denied' || state == 'restricted') {
      throw SimInjectFailure(
        GlintErrorKind.unsupportedBackendAction,
        'macOS camera access is $state for the app running glint',
        'the Mac camera needs the Camera permission of the terminal or editor that started glint',
        [
          'System Settings > Privacy & Security > Camera: allow the app that runs glint, then repeat the call',
          'or feed an image or video file instead (no permission needed)',
        ],
      );
    }
    if (statusText.contains('no camera')) {
      throw SimInjectFailure(GlintErrorKind.deviceNotConnected, 'this Mac has no camera glint can open', statusText,
          ['feed an image or video file, or source:"testcard", instead']);
    }
    if (ProcessRegistry.instance.processFor('webcam', device: injector.udid) != null) return _frames;
    injector.prepareControlDir();
    final marker = File('$_frames.read');
    if (marker.existsSync()) marker.deleteSync();
    final process = await startHelper('webcam', helper, [_frames],
        device: injector.udid, life: HelperLife.session, label: 'the Mac camera helper');
    unawaited(process.stderr.drain<void>());
    final ready = Completer<String>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!ready.isCompleted) ready.complete(line.trim());
    });
    unawaited(process.exitCode.then((code) {
      if (!ready.isCompleted) ready.complete(code == 3 ? 'denied' : 'exited $code');
    }));
    Future<String> firstLine() => ready.future.timeout(const Duration(seconds: 60), onTimeout: () => 'timeout');
    final first = await (phases?.during('opening the Mac camera (macOS may ask once for camera access)', firstLine) ??
        firstLine());
    if (!first.startsWith('ready')) {
      await ProcessRegistry.instance.stop('webcam', device: injector.udid);
      throw SimInjectFailure(
        GlintErrorKind.deviceNotConnected,
        'the Mac camera did not start',
        first == 'timeout' ? 'no camera frame arrived within 60 s (macOS camera access unanswered?)' : first,
        [
          'allow Camera for the app that runs glint (System Settings > Privacy & Security > Camera), then repeat the call',
          'or feed an image or video file instead',
        ],
      );
    }
    final reported = RegExp(r'protocol=(\d+)').firstMatch(first)?.group(1);
    if (reported != '$webcamProtocol') {
      await ProcessRegistry.instance.stop('webcam', device: injector.udid);
      throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, 'the Mac camera helper speaks another protocol',
          'helper reports ${reported ?? 'none'}, this glint needs $webcamProtocol', [
        'remove ~/.glint/bin/glint-webcam-* and repeat the call, or update glint',
      ]);
    }
    CallProgress.release(process);
    return _frames;
  }

  /// Stops the Mac camera pump of this simulator and deletes its frames.
  Future<void> stopWebcam() async {
    await ProcessRegistry.instance.stop('webcam', device: injector.udid);
    for (final name in const ['webcam.frames', 'webcam.frames.read', 'webcam.frames.tmp']) {
      final file = File('${injector.controlDir}/$name');
      if (file.existsSync()) file.deleteSync();
    }
  }

  Future<String> _webcamHelper(PhaseReporter? phases) async {
    final source = shippedPath(_webcamSource);
    if (source == null) {
      throw SimInjectFailure(GlintErrorKind.unsupportedToolchain,
          'the Mac camera helper is not part of this glint install', 'looked for $_webcamSource', ['reinstall glint']);
    }
    try {
      return await swiftHelper(source, 'glint-webcam', phase: 'building the Mac camera helper');
    } on SwiftHelperError catch (e) {
      throw SimInjectFailure(GlintErrorKind.unsupportedToolchain, e.message, e.detail,
          ['install Xcode and its command line tools (xcode-select --install), then retry']);
    }
  }
}
