import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../batch_runner.dart';
import '../envelope.dart';
import '../frame_sampling.dart';
import '../session.dart';
import '../tool_args.dart';
import '../tool.dart';

/// Records the display while a short step sequence runs and returns the distinct
/// frames, so an agent can see a screen that only flashes mid-transition.
class RecordTool extends GlintTool {
  const RecordTool();

  static const int _maxSteps = 20;
  static const _coordSteps = {'tap', 'long_press', 'swipe', 'drag'};

  @override
  Tool get definition => Tool(
        name: 'record',
        description:
            'Record the screen while running steps, then return the distinct '
            'frames as PNG files (read them in order). Use to see a transition '
            'or a screen that only flashes: repeated screenshots are too slow '
            'to catch it. steps:[{tool,args}] (same as batch, optional); '
            'durationMs is the passive capture with no steps, or the tail after '
            'them (default 400); everyMs is the sample interval (default 50); '
            'distinctOnly keeps one frame per run of near-identical frames '
            '(default true); maxFrames caps the output (default 12). errorKind: '
            'invalidArgument, unsupportedBackendAction (no recorder), '
            'appUnresponsive (app not answering), backendToolError (recorder failed).',
        inputSchema: ObjectSchema(
          properties: {
            'steps': batchStepsSchema(_maxSteps,
                description: 'Optional steps to run while recording. Max $_maxSteps.'),
            'durationMs': Schema.int(
                description:
                    'Passive capture with no steps, or the tail after them (0-30000). Default 400.'),
            'everyMs': Schema.int(
                description: 'Sample interval in ms (16-1000). Default 50.'),
            'distinctOnly': Schema.bool(
                description: 'Keep only frames that differ. Default true.'),
            'maxFrames':
                Schema.int(description: 'Max frames returned (1-60). Default 12.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final durationMs = (args['durationMs'] as int?) ?? 400;
    final everyMs = (args['everyMs'] as int?) ?? 50;
    final distinctOnly = (args['distinctOnly'] as bool?) ?? true;
    final maxFrames = (args['maxFrames'] as int?) ?? 12;

    if (durationMs < 0 || durationMs > 30000) {
      return _bad('durationMs must be 0-30000');
    }
    if (everyMs < 16 || everyMs > 1000) return _bad('everyMs must be 16-1000');
    if (maxFrames < 1 || maxFrames > 60) return _bad('maxFrames must be 1-60');

    final parsed =
        parseBatchSteps(args['steps'], maxSteps: _maxSteps, allowEmpty: true);
    if (parsed.error != null) return parsed.error!;
    final steps = parsed.steps!;
    if (steps.isEmpty && durationMs == 0) {
      return _bad('nothing to record: pass steps or durationMs > 0');
    }

    final app = session.active;
    if (app == null) {
      return StructuredResponse.error(
        summary: 'glint is not attached to an app',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: const ['call attach first'],
      );
    }
    if (!session.backend.capabilities.record) {
      return StructuredResponse.error(
        summary: '${session.backend.label} cannot record the display',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        nextSteps: const ['device op:screenshot for single frames'],
      );
    }
    if (app.activeRecording != null) {
      return _bad('a recording is already running on this device');
    }

    // Device mode: only coordinate gestures and hardware buttons can run.
    if (session.isDeviceMode) {
      for (var i = 0; i < steps.length; i++) {
        final st = steps[i];
        final ok = st.tool == 'hardware_button' ||
            (_coordSteps.contains(st.tool) &&
                (readPoint(st.args) != null || readSegment(st.args) != null));
        if (!ok) {
          return _bad('device mode: step ${i + 1} (${st.tool}) needs a Flutter '
              'app; use tap/swipe with x,y or hardware_button, or attach to the app');
        }
      }
    } else if (steps.isNotEmpty) {
      // The steps cannot run if the isolate is not answering.
      String? lifecycle;
      try {
        lifecycle =
            await session.lifecycleState().timeout(const Duration(seconds: 1));
      } on Object {
        return StructuredResponse.error(
          summary: 'the app is not answering, so the steps cannot run',
          errorKind: GlintErrorKind.appUnresponsive,
          nextSteps: const [
            'if the device is locked or a native layer is up, clear it first',
            'record durationMs:<n> with no steps to see what the device shows',
          ],
        );
      }
      if (lifecycle != null && lifecycle != 'resumed') {
        return StructuredResponse.error(
          summary: 'the app is $lifecycle, so the steps cannot drive it',
          errorKind: GlintErrorKind.appUnresponsive,
          nextSteps: const [
            'clear the native layer (see get_scene), then record again',
            'record durationMs:<n> with no steps to capture the current screen',
          ],
        );
      }
    }

    final dir = _prepareDir(app.id);
    final ScreenRecording recording;
    try {
      recording = await session.backend.startRecording('${dir.path}/video.mp4');
    } on BackendToolError catch (e) {
      return StructuredResponse.error(
        summary: 'could not start recording',
        errorKind: GlintErrorKind.backendToolError,
        detail: e.stderr,
        nextSteps: const [
          'only one recording per simulator at a time',
          'try `xcrun simctl io <udid> recordVideo --codec=h264 /tmp/t.mp4` to see the error',
        ],
      );
    }
    app.activeRecording = recording;

    final t0 = recording.startedAt;
    late final DateTime stopRequestedAt;
    BatchRun? run;
    String? video;
    try {
      if (steps.isNotEmpty) {
        run = await runBatchSteps(session, steps, stopOnNoChange: false);
      }
      await Future<void>.delayed(Duration(milliseconds: durationMs));
    } finally {
      stopRequestedAt = DateTime.now();
      try {
        video = await recording.stop();
      } on BackendToolError catch (e) {
        app.activeRecording = null;
        return StructuredResponse.error(
          summary: 'recording stopped but no video was written',
          errorKind: GlintErrorKind.backendToolError,
          detail: e.stderr,
        );
      }
      app.activeRecording = null;
    }
    final wallMs = stopRequestedAt.difference(t0).inMilliseconds;

    final bridge = session.device is IosSimulator
        ? (session.device as IosSimulator).bridgePath
        : resolveIosBridgePath(null);
    final extraction = await FrameExtractor(bridgePath: bridge).extract(
      video: video!,
      outDir: '${dir.path}/frames',
      everyMs: everyMs,
      maxFrames: maxFrames,
      distinctOnly: distinctOnly,
    );

    final frames = withHoldMs(extraction.frames, endMs: wallMs);
    final warnings = <String>[
      ...extraction.warnings,
      if (extraction.error != null)
        'frames not extracted: ${extraction.error}. The video is at $video. '
            'Build the bridge: cd native/ios_sim_bridge && swift build',
      if (extraction.error == null && frames.isEmpty)
        'no frames decoded from the video',
      if (frames.length == 1)
        'only one distinct frame in $wallMs ms: the screen did not change while '
            'recording, or changed faster than everyMs=$everyMs',
      if (extraction.capped)
        'capped at maxFrames=$maxFrames; raise maxFrames or everyMs for more',
      if (session.isDeviceMode) 'device mode: steps ran as coordinate gestures',
    ];

    final stepLines = run == null
        ? const <String>[]
        : [for (final o in run.outcomes) o.line(origin: t0)];

    return StructuredResponse(
      summary: [
        describeFrames(frames, wallMs, distinctOnly: distinctOnly),
        ...stepLines,
        if (frames.isNotEmpty)
          'frames are PNG files under ${dir.path}/frames; read them in order',
      ].join('\n'),
      warnings: warnings,
      nextSteps: [
        if (frames.isNotEmpty)
          'read ${frames.map((f) => f.path).take(4).join(", ")} to see what changed',
        if (frames.length == 1) 'record again with everyMs:16 for finer sampling',
      ],
      data: {
        'video': video,
        'dir': dir.path,
        'wallMs': wallMs,
        if (extraction.durationMs != null) 'videoMs': extraction.durationMs,
        'everyMs': everyMs,
        'distinctOnly': distinctOnly,
        'capped': extraction.capped,
        if (extraction.tool != null) 'extractedWith': extraction.tool,
        'frames': [for (final f in frames) f.toJson()],
        if (run != null)
          'steps': [for (final o in run.outcomes) o.toJson(origin: t0)],
        if (session.isDeviceMode) 'mode': 'device',
      },
    );
  }

  StructuredResponse _bad(String why) => StructuredResponse.error(
        summary: why,
        errorKind: GlintErrorKind.invalidArgument,
      );

  /// The per-recording frame directory, keeping only the newest three runs (frames are full-resolution PNGs).
  Directory _prepareDir(String deviceId) {
    final base = Directory('${Directory.systemTemp.path}/glint-captures/$deviceId');
    if (base.existsSync()) {
      final recs = base
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('rec-'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final old in recs.take(recs.length > 2 ? recs.length - 2 : 0)) {
        try {
          old.deleteSync(recursive: true);
        } on Object {
          // best-effort cleanup
        }
      }
    }
    final dir = Directory(
        '${base.path}/rec-${DateTime.now().millisecondsSinceEpoch}');
    dir.createSync(recursive: true);
    return dir;
  }
}
