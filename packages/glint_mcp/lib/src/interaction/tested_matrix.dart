import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// How far glint has proven one device setup.
enum SetupStatus { verified, partial, untested }

/// One device setup glint has driven end to end, with what proves it.
class TestedSetup {
  const TestedSetup({
    required this.platform,
    required this.backend,
    required this.runtimeMajor,
    this.xcodeMajor,
    this.hostMajor,
    required this.status,
    required this.checkedOn,
    required this.evidence,
    this.issues = const [],
  });

  /// `ios` or `android`.
  final String platform;

  /// Input path: glint-iossim's `dtuhid` or `indigo` transport, or `adb`.
  final String backend;

  /// iOS runtime major, or the Android API level.
  final int runtimeMajor;

  /// iOS only: the selected Xcode's major.
  final int? xcodeMajor;

  /// iOS only: the Mac's macOS major.
  final int? hostMajor;

  final SetupStatus status;
  final String checkedOn;
  final String evidence;

  /// Known problems on this setup, with issue numbers.
  final List<String> issues;

  String get label => platform == 'ios'
      ? 'iOS $runtimeMajor, Xcode $xcodeMajor, macOS $hostMajor, $backend'
      : 'Android API $runtimeMajor, $backend';

  Map<String, Object?> toJson() => {
        'setup': label,
        'status': status.name,
        'checkedOn': checkedOn,
        'evidence': evidence,
        if (issues.isNotEmpty) 'issues': issues,
      };
}

/// Every setup glint has been run on; update it when CI or a live run proves or breaks one.
const List<TestedSetup> testedSetups = [
  TestedSetup(
    platform: 'ios',
    backend: 'indigo',
    runtimeMajor: 26,
    xcodeMajor: 26,
    hostMajor: 26,
    status: SetupStatus.verified,
    checkedOn: '2026-09-27',
    evidence: 'CI device check on the macos-26 runner (Xcode 26.6, iPhone 17e)',
    issues: ['typing and scroll fail intermittently in CI (#75)'],
  ),
  TestedSetup(
    platform: 'ios',
    backend: 'dtuhid',
    runtimeMajor: 27,
    xcodeMajor: 27,
    hostMajor: 27,
    status: SetupStatus.verified,
    checkedOn: '2026-09-27',
    evidence: 'tap, type, keys, swipe and long press live on iPhone 17, iOS 27.0, with dtuhidd active (#74)',
    issues: ['native sheets presented inside the app (photo picker) are not detected (#80)'],
  ),
  TestedSetup(
    platform: 'ios',
    backend: 'indigo',
    runtimeMajor: 26,
    xcodeMajor: 27,
    hostMajor: 26,
    status: SetupStatus.partial,
    checkedOn: '2026-09-27',
    evidence: 'every bridge action on Xcode 27.0, iPhone 17, iOS 26.5 (#62)',
    issues: [_indigoDropped],
  ),
  TestedSetup(
    platform: 'ios',
    backend: 'indigo',
    runtimeMajor: 26,
    xcodeMajor: 27,
    hostMajor: 27,
    status: SetupStatus.partial,
    checkedOn: '2026-09-27',
    evidence: 'counter benchmark on iPhone 17, iOS 26.5',
    issues: [_indigoDropped],
  ),
  TestedSetup(
    platform: 'ios',
    backend: 'indigo',
    runtimeMajor: 27,
    xcodeMajor: 27,
    hostMajor: 27,
    status: SetupStatus.partial,
    checkedOn: '2026-09-27',
    evidence: 'Ember signup completed by an agent on iPhone 17, iOS 27.0 (#88)',
    issues: [
      _indigoDropped,
      'native sheets presented inside the app (photo picker) are not detected (#80)',
    ],
  ),
  TestedSetup(
    platform: 'android',
    backend: 'adb',
    runtimeMajor: 35,
    status: SetupStatus.verified,
    checkedOn: '2026-09-27',
    evidence: 'Ember signup completed by an agent on a Pixel 8 emulator (#88)',
  ),
  TestedSetup(
    platform: 'android',
    backend: 'adb',
    runtimeMajor: 34,
    status: SetupStatus.verified,
    checkedOn: '2026-09-27',
    evidence: 'CI device check on an x86_64 emulator',
  ),
];

const _indigoDropped =
    'the simulator drops indigo taps and keys once anything starts dtuhidd on the boot (#74); iosInput:auto picks dtuhid here';

/// The setup in front of glint at attach; null fields could not be read.
typedef DeviceSetup = ({
  String platform,
  String backend,
  int? runtimeMajor,
  String? runtime,
  int? xcodeMajor,
  int? hostMajor,
});

/// How [setup] compares with [testedSetups]: its status, the matching entry, and the closest proven one when it has none.
({SetupStatus status, TestedSetup? match, TestedSetup? closest}) judgeSetup(
    DeviceSetup setup,
    {List<TestedSetup> known = testedSetups}) {
  final same = known.where((t) =>
      t.platform == setup.platform &&
      t.backend == setup.backend &&
      t.runtimeMajor == setup.runtimeMajor);
  final exact = same.where((t) =>
      setup.platform != 'ios' ||
      (t.xcodeMajor == setup.xcodeMajor && t.hostMajor == setup.hostMajor));
  if (exact.isNotEmpty) {
    return (status: exact.first.status, match: exact.first, closest: null);
  }
  final pool = same.isNotEmpty
      ? same
      : known.where((t) => t.platform == setup.platform && t.backend == setup.backend);
  TestedSetup? closest;
  for (final t in pool) {
    if (closest == null || (t.status.index < closest.status.index)) closest = t;
  }
  return (status: SetupStatus.untested, match: null, closest: closest);
}

/// One line for the attach reply, plus warnings for anything short of verified.
({String line, List<String> warnings, Map<String, Object?> json}) describeSetup(
    DeviceSetup setup) {
  final v = judgeSetup(setup);
  final here = setup.platform == 'ios'
      ? '${setup.runtime ?? "iOS ?"}, Xcode ${setup.xcodeMajor ?? "?"}, macOS ${setup.hostMajor ?? "?"}, ${setup.backend}'
      : '${setup.runtime ?? "Android ?"}, ${setup.backend}';
  final warnings = switch (v.status) {
    SetupStatus.verified => [
        for (final i in v.match!.issues) 'known issue on this setup: $i',
      ],
    SetupStatus.partial => [
        'this setup works with known issues: ${v.match!.issues.join('; ')}',
      ],
    SetupStatus.untested => [
        'this setup is untested ($here)'
            '${v.closest != null ? "; closest proven: ${v.closest!.label} (${v.closest!.status.name})" : ""}'
            '; treat input failures as possibly glint\'s, and report them',
      ],
  };
  return (
    line: 'input: $here · ${v.status.name}',
    warnings: warnings,
    json: {
      'backend': setup.backend,
      'setup': here,
      'status': v.status.name,
      if (v.match != null) 'evidence': v.match!.evidence,
      if (v.match != null) 'checkedOn': v.match!.checkedOn,
      if (v.closest != null) 'closestProven': v.closest!.toJson(),
    },
  );
}

/// iOS runtime of simulator [udid] and the Mac's macOS major; [transport] is the bridge's input path.
Future<DeviceSetup> readIosSetup(String udid, int? xcodeMajor,
    {String transport = 'indigo', ProcessRunner run = Process.run}) async {
  String? runtime;
  int? runtimeMajor;
  try {
    final r = await run('xcrun', ['simctl', 'list', 'devices', '-j']);
    final devices = (jsonDecode(r.stdout as String) as Map)['devices'] as Map;
    for (final entry in devices.entries) {
      if ((entry.value as List).any((d) => d is Map && d['udid'] == udid)) {
        final m = RegExp(r'SimRuntime\.iOS-(\d+)-(\d+)').firstMatch(entry.key as String);
        if (m != null) {
          runtimeMajor = int.parse(m.group(1)!);
          runtime = 'iOS ${m.group(1)}.${m.group(2)}';
        }
      }
    }
  } on Object {
    // unknown runtime: judged as untested
  }
  return (
    platform: 'ios',
    backend: transport,
    runtimeMajor: runtimeMajor,
    runtime: runtime,
    xcodeMajor: xcodeMajor,
    hostMajor: await _hostMajor(run),
  );
}

/// The input transport glint-iossim opens for [udid] under [mode]; [fallback] says why `auto` settled for indigo.
Future<({String? transport, String? fallback, String? error})> readIosTransport(
    String bridgePath, String udid, String mode,
    {ProcessRunner run = Process.run}) async {
  try {
    final r = await run(bridgePath, [if (mode != 'auto') ...['--hid', mode], 'hid', udid])
        .timeout(const Duration(seconds: 30));
    final m = RegExp(r'^hid (\w+) coresimulator \S+(?: \(dtuhid unavailable: (.*)\))?$', multiLine: true)
        .firstMatch('${r.stdout}');
    if (r.exitCode == 0 && m != null) {
      return (transport: m.group(1), fallback: m.group(2), error: null);
    }
    final err = '${r.stderr}'.trim();
    return (transport: null, fallback: null, error: err.isEmpty ? 'the bridge did not name its transport' : err);
  } on Object catch (e) {
    return (transport: null, fallback: null, error: '$e');
  }
}

/// Android API level of [serial].
Future<DeviceSetup> readAndroidSetup(String serial, String adbPath,
    {ProcessRunner run = Process.run}) async {
  int? api;
  try {
    final r = await run(adbPath, ['-s', serial, 'shell', 'getprop', 'ro.build.version.sdk']);
    api = int.tryParse((r.stdout as String).trim());
  } on Object {
    // unknown API: judged as untested
  }
  return (
    platform: 'android',
    backend: 'adb',
    runtimeMajor: api,
    runtime: api == null ? null : 'Android API $api',
    xcodeMajor: null,
    hostMajor: null,
  );
}

Future<int?> _hostMajor(ProcessRunner run) async {
  try {
    final r = await run('sw_vers', ['-productVersion']);
    return int.tryParse((r.stdout as String).trim().split('.').first);
  } on Object {
    return null;
  }
}
