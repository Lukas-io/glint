import 'dart:async';

import 'package:glint_core/glint_core.dart' show ProcessRegistry, redactForSharing;

import '../../interaction.dart';
import '../../observability.dart';
import 'app_session.dart';

/// Milliseconds a call must run before the live helpers are sampled for CPU.
const int kHelperSampleAfterMs = 3000;

/// Gap between wall clock and awake time that marks a sleep or clock jump.
const int kWallJumpMs = 2000;

const _budgetArgs = ['timeoutMs', 'readyTimeoutMs', 'afterMs', 'durationMs', 'maxScrolls'];

/// The local-only usage fields for one finished call: where it ran, how long each phase took, the shape of its request and what failed. Never argument values, names, ids or paths.
Map<String, Object?> callDiagnostics({
  required Map<String, Object?>? args,
  required Map<String, Object?>? data,
  required AppSession? app,
  required int appCount,
  required int wallMs,
  CallProgress? call,
  CallMark base = const CallMark(),
  Object? failure,
  String? batchId,
  int? batchStep,
}) {
  final out = <String, Object?>{};
  if (app != null) out.addAll(_deviceFields(app));
  out['apps'] = appCount;
  if (call != null) out.addAll(_timingFields(call, base, wallMs));
  final budgets = requestBudgets(args);
  if (budgets.isNotEmpty) out['budgets'] = budgets;
  if (data?['input'] case final Map input) {
    final path = input['path'];
    final reason = input['reason'];
    if (path is String) out['input_path'] = path;
    if (reason is String) out['input_reason'] = reason;
  }
  if (failure != null) out['inner_error'] = _errorClass(failure);
  out['in_flight'] = CallProgress.inFlight;
  if (call != null) out['progress_token'] = call.token != null;
  if (batchId != null) out['batch_id'] = batchId;
  if (batchStep != null) out['batch_step'] = batchStep;
  return out;
}

Map<String, Object?> _deviceFields(AppSession app) {
  final device = app.device;
  final (platform, kind) = switch (device) {
    IosSimulator() => ('ios', 'simulator'),
    IosDevice() => ('ios', 'physical'),
    AndroidDevice(:final serial) => ('android', serial.startsWith('emulator-') ? 'emulator' : 'physical'),
  };
  final backend = switch (device) {
    IosSimulator(:final runner) => runner == null ? 'iossim' : 'xctest',
    IosDevice() => 'devicehid',
    AndroidDevice(:final server) => server == null ? 'adb' : 'adb_server',
  };
  final os = app.osVersion;
  return {
    'platform': platform,
    'device_kind': kind,
    if (os != null && _plainVersion.hasMatch(os)) 'os_version': os,
    'app_mode': app.deviceMode ? 'device' : (app.sceneMode == SceneMode.native ? 'native' : 'flutter'),
    'input_route': device.route.name,
    'input_backend': backend,
  };
}

final RegExp _plainVersion = RegExp(r'^[A-Za-z0-9 .\-]{1,24}$');

Map<String, Object?> _timingFields(CallProgress call, CallMark base, int wallMs) {
  final now = call.mark();
  final monoMs = now.atMs - base.atMs;
  final phases = <String, int>{
    for (final e in now.phases.entries)
      if (e.value - (base.phases[e.key] ?? 0) >= 1) e.key: e.value - (base.phases[e.key] ?? 0),
  };
  final top = phases.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final timeouts = now.vmTimeouts - base.vmTimeouts;
  final retries = now.vmRetries - base.vmRetries;
  return {
    'wall_ms': wallMs,
    'mono_ms': monoMs,
    'wall_jump': (wallMs - monoMs).abs() > kWallJumpMs,
    if (top.isNotEmpty) 'phases': {for (final e in top.take(12)) e.key: e.value},
    if (timeouts > 0) 'vm_timeouts': timeouts,
    if (retries > 0) 'vm_retries': retries,
  };
}

/// The requested waits and limits in `args`, each as a coarse bucket and never the number itself.
Map<String, String> requestBudgets(Map<String, Object?>? args) {
  final out = <String, String>{};
  if (args == null) return out;
  for (final name in _budgetArgs) {
    final value = args[name];
    if (value is! num) continue;
    out[name] = name == 'maxScrolls' ? _countBucket(value) : _msBucket(value);
  }
  return out;
}

String _msBucket(num ms) {
  if (ms <= 0) return '0';
  if (ms <= 1000) return 'le1s';
  if (ms <= 5000) return 'le5s';
  if (ms <= 15000) return 'le15s';
  if (ms <= 60000) return 'le60s';
  return 'gt60s';
}

String _countBucket(num n) {
  if (n <= 5) return 'le5';
  if (n <= 15) return 'le15';
  if (n <= 40) return 'le40';
  return 'gt40';
}

final RegExp _className = RegExp(r'^[A-Za-z_][A-Za-z0-9_<>, ]{0,60}$');

String _errorClass(Object failure) {
  final name = failure.runtimeType.toString();
  return _className.hasMatch(name) ? redactForSharing(name) : 'other';
}

/// The helper fields for a call that started at [start], empty unless it ran past [kHelperSampleAfterMs]; capped at 300 ms so the reply never waits longer.
Future<Map<String, Object?>> helperFields(DateTime start) async {
  if (DateTime.now().difference(start).inMilliseconds < kHelperSampleAfterMs) return const {};
  if (CallProgress.current?.abandoned ?? false) return const {};
  return await sampleHelpers().timeout(_helperSampleCap, onTimeout: () => null) ?? const {};
}

const Duration _helperSampleCap = Duration(milliseconds: 300);

/// How many helpers this process holds and their summed CPU percent from one bounded `ps`; null when there are none or `ps` fails.
Future<Map<String, Object?>?> sampleHelpers() => Zone.root.run(() async {
      final pids = ProcessRegistry.instance.livePids;
      if (pids.isEmpty) return null;
      try {
        final r = await runBounded('ps', ['-o', 'pcpu=', '-p', pids.join(',')], timeout: _helperSampleCap, phase: 'ps');
        final cpu = '${r.stdout}'
            .split('\n')
            .map((l) => double.tryParse(l.trim().replaceAll(',', '.')) ?? 0)
            .fold<double>(0, (a, b) => a + b);
        return {'helpers': pids.length, 'helper_cpu': double.parse(cpu.toStringAsFixed(1))};
      } on Object {
        return {'helpers': pids.length};
      }
    });
