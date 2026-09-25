import 'dart:async';
import 'dart:io';

import 'backend.dart';
import 'bridge_download.dart';
import 'bridge_locator.dart';

/// Xcode majors the bridge's private CoreSimulator and IndigoHID calls are verified on.
const Set<int> testedXcodeMajors = {26};

/// Must equal `bridgeProtocol` in native/ios_sim_bridge/Sources/glint-iossim/main.swift.
const int expectedBridgeProtocol = 1;

/// Env var that lets bridge actions run on an Xcode major outside [testedXcodeMajors].
const String allowUntestedXcodeEnv = 'GLINT_ALLOW_UNTESTED_XCODE';

class XcodeInfo {
  const XcodeInfo({this.version, this.developerDir, this.error});

  final String? version;
  final String? developerDir;

  /// Why the version could not be read.
  final String? error;

  int? get major =>
      version == null ? null : int.tryParse(version!.split('.').first);

  bool get tested => major != null && testedXcodeMajors.contains(major);
}

/// Reads the selected Xcode's version from `xcode-select -p` and its Info.plist.
Future<XcodeInfo> detectXcode({ProcessRunner run = Process.run}) async {
  final ProcessResult selected;
  try {
    selected = await run('xcode-select', ['-p']);
  } on ProcessException catch (e) {
    return XcodeInfo(error: 'xcode-select not found: ${e.message}');
  }
  final dir = ((selected.stdout as String?) ?? '').trim();
  if (selected.exitCode != 0 || dir.isEmpty) {
    return XcodeInfo(error: 'xcode-select -p failed: ${selected.stderr}'.trim());
  }
  if (!dir.contains('.app/')) {
    return XcodeInfo(
        developerDir: dir,
        error: 'the selected developer dir is not an Xcode app ($dir)');
  }
  final plist = '${dir.substring(0, dir.lastIndexOf('/'))}/Info.plist';
  final read = await run(
      'plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', plist]);
  final version = ((read.stdout as String?) ?? '').trim();
  if (read.exitCode != 0 || version.isEmpty) {
    return XcodeInfo(developerDir: dir, error: 'could not read $plist');
  }
  return XcodeInfo(version: version, developerDir: dir);
}

/// Asks the bridge for its protocol number; null with [error] when it cannot say.
Future<({int? protocol, String? error})> bridgeHandshake(String path,
    {ProcessRunner run = Process.run}) async {
  try {
    final res = await run(path, ['version']).timeout(const Duration(seconds: 5));
    final m = RegExp(r'glint-iossim (\d+)').firstMatch('${res.stdout}');
    if (res.exitCode == 0 && m != null) {
      return (protocol: int.parse(m.group(1)!), error: null);
    }
    return (protocol: null, error: 'the bridge predates the version handshake');
  } on ProcessException catch (e) {
    return (protocol: null, error: 'could not run the bridge: ${e.message}');
  } on TimeoutException {
    return (protocol: null, error: 'the bridge did not answer `version` in 5s');
  }
}

/// What glint knows about the iOS toolchain at attach: Xcode, the bridge, and whether bridge actions may run.
class IosToolchain {
  const IosToolchain({
    required this.xcode,
    required this.bridge,
    this.bridgeProtocol,
    this.bridgeError,
    this.downloadError,
    this.allowUntested = false,
  });

  final XcodeInfo xcode;
  final BridgeLocation bridge;
  final int? bridgeProtocol;
  final String? bridgeError;
  final String? downloadError;
  final bool allowUntested;

  bool get _untestedXcode => xcode.major != null && !xcode.tested;

  /// Why bridge actions are refused; null when they may run.
  String? get blocker {
    if (!bridge.found) {
      return 'the glint-iossim bridge is not installed'
          '${downloadError != null ? ": $downloadError" : ""}';
    }
    if (_untestedXcode && !allowUntested) {
      return 'Xcode ${xcode.version} is untested: glint drives the simulator '
          'through private Xcode APIs verified on Xcode '
          '${testedXcodeMajors.join(", ")} only';
    }
    return null;
  }

  List<String> get nextSteps => [
        if (!bridge.found) ...[
          'build it: cd <glint>/native/ios_sim_bridge && swift build -c release',
          'or point $bridgePathEnv at a glint-iossim binary',
        ],
        if (bridge.found && _untestedXcode && !allowUntested) ...[
          'switch to a tested Xcode with xcode-select -s',
          'or set $allowUntestedXcodeEnv=true in the MCP server env to try anyway',
        ],
      ];

  List<String> get warnings => [
        if (blocker != null) '$blocker; tap / swipe / type will be refused',
        if (bridge.found && _untestedXcode && allowUntested)
          'Xcode ${xcode.version} is untested; $allowUntestedXcodeEnv is on, so '
              'bridge actions run anyway and may misbehave',
        if (xcode.error != null) 'could not read the Xcode version: ${xcode.error}',
        if (bridge.found && bridgeError != null)
          '$bridgeError; rebuild it: swift build -c release in native/ios_sim_bridge',
        if (bridgeProtocol != null && bridgeProtocol != expectedBridgeProtocol)
          'bridge protocol $bridgeProtocol, glint expects $expectedBridgeProtocol; '
              'rebuild it: swift build -c release in native/ios_sim_bridge',
      ];

  Map<String, Object?> toJson() => {
        'xcode': xcode.version,
        'bridge': bridge.source.name,
        if (bridgeProtocol != null) 'bridgeProtocol': bridgeProtocol,
        'actionsAllowed': blocker == null,
      };
}

/// Bridge actions refused because the bridge is missing or Xcode is untested.
class IosToolchainBlocked extends UnsupportedBackendAction {
  IosToolchainBlocked(super.backend, super.detail, this.nextSteps);

  final List<String> nextSteps;
}

/// The last failed download and when it failed; attaches within [_retryAfter] reuse it instead of refetching.
({String error, DateTime at})? _lastDownloadFailure;
const _retryAfter = Duration(minutes: 10);

/// Locates (downloading when missing) and handshakes the bridge, and reads Xcode.
Future<IosToolchain> checkIosToolchain(String? explicitBridge,
    {Map<String, String>? env,
    ProcessRunner run = Process.run,
    BytesFetcher? fetch,
    void Function(String phase)? onPhase}) async {
  final environment = env ?? Platform.environment;
  var bridge = locateIosBridge(explicitBridge, env: environment);
  String? downloadError;
  if (!bridge.found) {
    final recent = _lastDownloadFailure;
    if (environment[noBridgeDownloadEnv] == 'true') {
      downloadError = '$noBridgeDownloadEnv is set';
    } else if (fetch == null &&
        recent != null &&
        DateTime.now().difference(recent.at) < _retryAfter) {
      downloadError = recent.error;
    } else {
      try {
        await downloadBridge(bridge.path, fetch: fetch, onPhase: onPhase);
        bridge = BridgeLocation(bridge.path, BridgeSource.cache);
      } on BridgeDownloadError catch (e) {
        downloadError = e.message;
      } on FileSystemException catch (e) {
        downloadError = 'could not save it to ${bridge.path}: ${e.message}';
      }
      if (downloadError != null) {
        _lastDownloadFailure = (error: downloadError, at: DateTime.now());
      }
    }
  } else if (!File(bridge.path).existsSync()) {
    bridge = BridgeLocation(bridge.path, BridgeSource.missing);
    downloadError = 'no file at ${bridge.path}';
  }
  final results = await Future.wait([
    detectXcode(run: run),
    if (bridge.found) bridgeHandshake(bridge.path, run: run),
  ]);
  final handshake = bridge.found
      ? results[1] as ({int? protocol, String? error})
      : null;
  return IosToolchain(
    xcode: results[0] as XcodeInfo,
    bridge: bridge,
    bridgeProtocol: handshake?.protocol,
    bridgeError: handshake?.error,
    downloadError: downloadError,
    allowUntested: environment[allowUntestedXcodeEnv] == 'true',
  );
}
