import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../sensors/motion.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../xctest_start.dart';

/// `sensors` — read, and on emulators and simulators drive, how the device is held: orientation (face up and down too), rotation lock and motion samples.
class SensorsTool extends GlintTool {
  const SensorsTool();

  static const _maxSteps = 30;

  @override
  Tool get definition => Tool(
        name: 'sensors',
        description:
            'How the device is held. op: read (default): deviceOrientation (portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown), interfaceOrientation, rotationLocked, and on Android the newest accelerometer, gyroscope and magnetic field samples. op: set orientation:<one of those> (Android emulator: through its accelerometer, so the app\'s motion sensors agree; iOS simulator: through the XCTest runner), or acceleration:[x,y,z] on the Android emulator. op: script steps:[{orientation}|{acceleration}|{waitMs}|{shake:true}] runs a motion sequence (shake: Android emulator). Physical Android phones read only; physical iPhones are not supported. errorKind: invalidArgument, unsupportedBackendAction, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'read (default) | set | script'),
            'orientation': Schema.string(
                description:
                    'set: portrait | portraitUpsideDown | landscapeLeft | landscapeRight | faceUp | faceDown.'),
            'acceleration': Schema.list(
                items: Schema.num(), description: 'set (Android emulator): [x, y, z] in m/s², Android axes.'),
            'steps': Schema.list(
              description:
                  'script: up to $_maxSteps of {orientation}, {acceleration:[x,y,z]}, {waitMs} (up to 10000) or {shake:true}.',
              items: ObjectSchema(properties: {
                'orientation': Schema.string(),
                'acceleration': Schema.list(items: Schema.num()),
                'waitMs': Schema.int(),
                'shake': Schema.bool(),
              }),
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'read';
    if (!const {'read', 'set', 'script'}.contains(op)) return _bad('unknown op "$op"', 'use read, set or script');
    final app = session.active;
    if (app == null) throw SessionNotAttachedError(missing: 'app');
    final dev = app.device;
    final _Motion? motion = switch (dev) {
      AndroidDevice() => _AndroidMotion(dev),
      IosSimulator() => await _IosMotion.open(session, dev, request),
      IosDevice() => switch (phoneHid(session.backend)) { final hid? => _PhoneMotion(hid), null => null },
    };
    if (motion == null) {
      return StructuredResponse.refuse(dev, Ability.sensors) ??
          StructuredResponse.error(
              summary: 'sensors are not available on ${dev.id}', errorKind: GlintErrorKind.notOnThisDevice);
    }
    if (motion is _IosMotion && motion.error != null) return motion.error!;

    switch (op) {
      case 'read':
        return _reply(await motion.read(session), 'read');
      case 'set':
        final step = _step(args);
        if (step.error != null) return step.error!;
        if (step.step!.containsKey('waitMs') || step.step!.containsKey('shake')) {
          return _bad('op:set takes orientation or acceleration', 'use op:script for waits and shakes');
        }
        final refused = await motion.apply(step.step!);
        if (refused != null) return refused;
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        final state = await motion.read(session);
        final wanted = step.step!['orientation'] as String?;
        final warnings = [
          if (wanted != null && state.deviceOrientation != null && state.deviceOrientation != wanted)
            'the device reads ${state.deviceOrientation}, not $wanted',
          if (state.rotationLocked == true && (wanted?.startsWith('landscape') ?? false))
            'rotation is locked, so the interface stays ${state.interfaceOrientation}',
          if (state.rotationLocked == false &&
              (wanted?.startsWith('landscape') ?? false) &&
              !(state.interfaceOrientation ?? '').startsWith('landscape'))
            'the screen in front did not rotate: it may allow portrait only (a launcher does), or the app is in the background',
        ];
        return _reply(state, 'set ${wanted ?? 'acceleration ${step.step!['acceleration']}'}', warnings: warnings);
      default:
        final raw = args['steps'];
        if (raw is! List || raw.isEmpty || raw.length > _maxSteps) {
          return _bad('op:script needs 1-$_maxSteps steps',
              'steps:[{orientation:"faceUp"},{waitMs:2000},{orientation:"portrait"}]');
        }
        final steps = <Map<String, Object?>>[];
        for (final (i, s) in raw.indexed) {
          final parsed = _step(s is Map ? s.cast<String, Object?>() : const {});
          if (parsed.error != null) return parsed.error!.copyWith(summary: 'step ${i + 1}: ${parsed.error!.summary}');
          steps.add(parsed.step!);
        }
        for (final (i, s) in steps.indexed) {
          final refused = s.containsKey('waitMs') ? null : motion.refuses(s);
          if (refused != null) return refused.copyWith(summary: 'step ${i + 1}: ${refused.summary}; nothing was run');
        }
        final token = request.meta?.progressToken;
        final notifier = session.progressNotifier;
        final began = DateTime.now();
        var at = 0;
        final ticker = token == null || notifier == null
            ? null
            : Timer.periodic(const Duration(seconds: 15), (_) {
                final sec = DateTime.now().difference(began).inSeconds;
                notifier(ProgressNotification(
                    progressToken: token, progress: sec, message: 'step $at of ${steps.length} (${sec}s)'));
              });
        final done = <String>[];
        try {
          for (final (i, s) in steps.indexed) {
            at = i + 1;
            final wait = s['waitMs'] as int?;
            if (wait != null) {
              await Future<void>.delayed(Duration(milliseconds: wait));
              done.add('waited ${wait}ms');
              continue;
            }
            final refused = await motion.apply(s);
            if (refused != null) {
              return refused.copyWith(summary: 'step $at: ${refused.summary}').mergeData({'completed': done});
            }
            done.add(s['shake'] == true
                ? 'shook'
                : s['orientation'] != null
                    ? '${s['orientation']}'
                    : 'acceleration ${s['acceleration']}');
          }
        } finally {
          ticker?.cancel();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return _reply(await motion.read(session), 'ran ${steps.length} step(s): ${done.join(' → ')}');
    }
  }

  ({Map<String, Object?>? step, StructuredResponse? error}) _step(Map<String, Object?> s) {
    final orientation = s['orientation'] as String?;
    final acc = s['acceleration'];
    final wait = s['waitMs'];
    final shake = s['shake'] == true;
    final given = [orientation != null, acc != null, wait != null, shake].where((b) => b).length;
    if (given != 1) {
      return (
        step: null,
        error: _bad('give exactly one of orientation, acceleration, waitMs or shake', 'e.g. {orientation:"faceUp"}')
      );
    }
    if (orientation != null && !restingAcceleration.containsKey(orientation)) {
      return (
        step: null,
        error: _bad('unknown orientation "$orientation"', 'one of ${restingAcceleration.keys.join(', ')}')
      );
    }
    if (acc != null && (acc is! List || acc.length != 3 || acc.any((v) => v is! num))) {
      return (
        step: null,
        error: _bad('acceleration is [x, y, z] in m/s²', 'e.g. acceleration:[0, 0, 9.81] lies it face up')
      );
    }
    if (wait != null && (wait is! num || wait < 0 || wait > 10000)) {
      return (step: null, error: _bad('waitMs must be 0-10000', 'split a longer pause'));
    }
    return (
      step: {
        if (orientation != null) 'orientation': orientation,
        if (acc != null) 'acceleration': [for (final v in acc as List) (v as num).toDouble()],
        if (wait != null) 'waitMs': (wait as num).toInt(),
        if (shake) 'shake': true,
      },
      error: null,
    );
  }

  StructuredResponse _reply(_MotionState s, String did, {List<String> warnings = const []}) {
    String v(List<double>? xs) => xs == null ? 'none' : xs.map((x) => x.toStringAsFixed(2)).join(', ');
    return StructuredResponse(
      summary: [
        '$did: device ${s.deviceOrientation ?? 'unknown'}, interface ${s.interfaceOrientation ?? 'unknown'}'
            '${s.rotationLocked == null ? '' : s.rotationLocked! ? ', rotation locked' : ', auto-rotate on'}',
        if (s.accelerometer != null)
          'accelerometer ${v(s.accelerometer)} m/s²${s.sampledAt == null ? '' : ' at ${s.sampledAt}'}',
        if (s.gyroscope != null) 'gyroscope ${v(s.gyroscope)} rad/s',
      ].join('\n'),
      warnings: [...warnings, ...s.notes],
      data: {
        'deviceOrientation': s.deviceOrientation,
        'interfaceOrientation': s.interfaceOrientation,
        if (s.rotationLocked != null) 'rotationLocked': s.rotationLocked,
        if (s.accelerometer != null) 'accelerometer': s.accelerometer,
        if (s.gyroscope != null) 'gyroscope': s.gyroscope,
        if (s.magneticField != null) 'magneticField': s.magneticField,
        if (s.sampledAt != null) 'sampledAt': s.sampledAt,
        'source': s.source,
      },
    );
  }

  static StructuredResponse _bad(String summary, String next) =>
      StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument, nextSteps: [next]);
}

class _MotionState {
  _MotionState({
    this.deviceOrientation,
    this.interfaceOrientation,
    this.rotationLocked,
    this.accelerometer,
    this.gyroscope,
    this.magneticField,
    this.sampledAt,
    required this.source,
    this.notes = const [],
  });

  final String? deviceOrientation;
  final String? interfaceOrientation;
  final bool? rotationLocked;
  final List<double>? accelerometer;
  final List<double>? gyroscope;
  final List<double>? magneticField;
  final String? sampledAt;
  final String source;
  final List<String> notes;
}

sealed class _Motion {
  Future<_MotionState> read(GlintSession session);

  /// Why this device cannot take [step], or null when it can.
  StructuredResponse? refuses(Map<String, Object?> step);

  /// Applies one orientation, acceleration or shake step; the error when this device cannot.
  Future<StructuredResponse?> apply(Map<String, Object?> step) async => refuses(step) ?? await _apply(step);

  Future<StructuredResponse?> _apply(Map<String, Object?> step);
}

class _AndroidMotion extends _Motion {
  _AndroidMotion(this.dev);
  final AndroidDevice dev;

  bool get _emulator => dev.serial.startsWith('emulator-');

  Future<ProcessResult> _adb(List<String> args) => Process.run(dev.adbPath, ['-s', dev.serial, ...args]);

  @override
  Future<_MotionState> read(GlintSession session) async {
    final samples = parseSensorService('${(await _adb(['shell', 'dumpsys', 'sensorservice'])).stdout}');
    var acc = samples['accelerometer']?.values;
    var gyro = samples['gyroscope']?.values;
    if (_emulator) {
      acc = _console('${(await _adb(['emu', 'sensor', 'get', 'acceleration'])).stdout}') ?? acc;
      gyro = _console('${(await _adb(['emu', 'sensor', 'get', 'gyroscope'])).stdout}') ?? gyro;
    }
    final rotation = displayRotation('${(await _adb(['shell', 'dumpsys', 'window', 'displays'])).stdout}');
    final auto = '${(await _adb(['shell', 'settings', 'get', 'system', 'accelerometer_rotation'])).stdout}'.trim();
    return _MotionState(
      deviceOrientation: acc == null ? null : orientationFromAcceleration(acc),
      interfaceOrientation: rotation == null ? null : interfaceOrientationFor(rotation),
      rotationLocked: auto == '0'
          ? true
          : auto == '1'
              ? false
              : null,
      accelerometer: acc,
      gyroscope: gyro,
      magneticField: samples['magneticField']?.values,
      sampledAt: _emulator ? null : samples['accelerometer']?.wall,
      source: _emulator ? 'emulator sensors' : 'dumpsys sensorservice',
      notes: [
        if (acc == null)
          'no app is reading the accelerometer, so Android keeps no recent sample; turn auto-rotate on or open a screen that uses motion',
      ],
    );
  }

  @override
  StructuredResponse? refuses(Map<String, Object?> step) => _emulator
      ? null
      : StructuredResponse.error(
          summary: 'a physical phone\'s sensors cannot be driven',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          nextSteps: const ['ask the user to hold the phone that way, then op:read to confirm'],
        );

  @override
  Future<StructuredResponse?> _apply(Map<String, Object?> step) async {
    if (step['shake'] == true) {
      final base = _console('${(await _adb(['emu', 'sensor', 'get', 'acceleration'])).stdout}') ??
          restingAcceleration['portrait']!;
      for (var i = 0; i < 6; i++) {
        final x = i.isEven ? 18.0 : -18.0;
        if (!await _set([base[0] + x, base[1], base[2]])) return _failed();
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      return await _set(base) ? null : _failed();
    }
    final acc = (step['acceleration'] as List<double>?) ?? restingAcceleration[step['orientation']]!;
    return await _set(acc) ? null : _failed();
  }

  Future<bool> _set(List<double> a) async {
    final r = await _adb(['emu', 'sensor', 'set', 'acceleration', a.map((v) => v.toStringAsFixed(3)).join(':')]);
    return r.exitCode == 0 && '${r.stdout}'.contains('OK');
  }

  StructuredResponse _failed() => StructuredResponse.error(
        summary: 'the emulator console refused the sensor change',
        errorKind: GlintErrorKind.backendToolError,
        nextSteps: const ['check `adb emu sensor status` lists acceleration as enabled'],
      );

  static List<double>? _console(String out) {
    final m = RegExp(r'=\s*([-\d.]+):([-\d.]+):([-\d.]+)').firstMatch(out);
    return m == null ? null : [for (var i = 1; i <= 3; i++) double.parse(m.group(i)!)];
  }
}

/// A physical iPhone: the interface orientation from SpringBoard, read through the Device Hub helper.
class _PhoneMotion extends _Motion {
  _PhoneMotion(this.hid);
  final DeviceHid hid;

  @override
  Future<_MotionState> read(GlintSession session) async {
    final r = await hid.call(const {'cmd': 'orientation'});
    final raw = '${r['interfaceOrientation']}';
    final name = raw.isEmpty ? null : raw[0].toLowerCase() + raw.substring(1);
    return _MotionState(
      interfaceOrientation: name == 'unknown' ? null : name,
      source: 'SpringBoard through Device Hub',
      notes: const ['a physical iPhone reports its interface orientation only, not its motion sensors'],
    );
  }

  static const _turnable = {'portrait', 'portraitUpsideDown', 'landscapeLeft', 'landscapeRight'};

  @override
  StructuredResponse? refuses(Map<String, Object?> step) => _turnable.contains(step['orientation'])
      ? null
      : StructuredResponse.error(
          summary:
              'a physical iPhone turns to portrait, portraitUpsideDown, landscapeLeft or landscapeRight only; it has no motion sensors glint can set',
          errorKind: GlintErrorKind.notOnThisDevice,
          nextSteps: const ['use an orientation step, or the Android emulator for acceleration and shake'],
        ).mergeData({'ability': 'sensors'});

  String _name(Object? raw) {
    final s = '$raw';
    return s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
  }

  /// Turns the phone a quarter at a time, the way Device Hub's rotate button does, until it reports [step]'s orientation.
  @override
  Future<StructuredResponse?> _apply(Map<String, Object?> step) async {
    final want = step['orientation']! as String;
    for (var turn = 0; turn < 4; turn++) {
      final now = _name((await hid.call(const {'cmd': 'orientation'}))['interfaceOrientation']);
      if (now == want) return null;
      final r = await hid.call(const {'cmd': 'rotate', 'direction': 'right'});
      if (r['locked'] == true) {
        return StructuredResponse.error(
          summary: 'the iPhone has rotation lock on, so it stays $now',
          errorKind: GlintErrorKind.notOnThisDevice,
          nextSteps: const [
            'turn rotation lock off in Control Center (swipe down from the top-right, tap the lock), then retry'
          ],
        ).mergeData({'ability': 'sensors'});
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return StructuredResponse.error(
      summary: 'the iPhone did not turn to $want',
      errorKind: GlintErrorKind.notOnThisDevice,
      detail: 'the app in front may support fewer orientations; the interface stays as the app allows',
      nextSteps: const [
        'read the orientations the app declares (UISupportedInterfaceOrientations), or try another app'
      ],
    ).mergeData({'ability': 'sensors'});
  }
}

class _IosMotion extends _Motion {
  _IosMotion._(this.runner, this.error);

  final XcTestRunner? runner;
  final StructuredResponse? error;

  static Future<_IosMotion> open(GlintSession session, IosSimulator dev, CallToolRequest request) async {
    final got = await xcTestRunnerFor(session, dev, request);
    return _IosMotion._(got.runner, got.error);
  }

  @override
  Future<_MotionState> read(GlintSession session) async {
    final r = await runner!.call('GET', '/orientation');
    String? ui;
    try {
      ui = (await session.uiState()).orientation;
    } on Object {
      ui = null;
    }
    return _MotionState(
      deviceOrientation: r['orientation'] as String?,
      interfaceOrientation: ui,
      source: 'XCTest runner',
      notes: const ['the iOS simulator has no accelerometer or gyroscope; only the orientation it reports to apps'],
    );
  }

  @override
  StructuredResponse? refuses(Map<String, Object?> step) => step['orientation'] != null
      ? null
      : StructuredResponse.error(
          summary: 'the iOS simulator takes orientations only: it has no accelerometer to set or shake',
          errorKind: GlintErrorKind.unsupportedBackendAction,
          nextSteps: const ['use orientation steps, or the Android emulator for acceleration and shake'],
        );

  @override
  Future<StructuredResponse?> _apply(Map<String, Object?> step) async {
    final orientation = step['orientation']! as String;
    try {
      await runner!.call('POST', '/orientation', body: {'orientation': orientation});
      return null;
    } on XcTestRunnerError catch (e) {
      return StructuredResponse.error(
          summary: e.message, errorKind: GlintErrorKind.backendToolError, detail: e.detail, nextSteps: e.nextSteps);
    }
  }
}
