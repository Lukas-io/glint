import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:glint_mcp/glint.dart';
import 'package:test/test.dart';

ProcessRunner _runner(Map<String, ProcessResult> byCommand, {List<String>? calls}) =>
    (exe, args) async {
      calls?.add([exe, ...args].join(' '));
      final key = byCommand.keys.firstWhere(
          (k) => [exe, ...args].join(' ').startsWith(k),
          orElse: () => throw ProcessException(exe, args, 'not found'));
      return byCommand[key]!;
    };

ProcessResult _ok(String out) => ProcessResult(0, 0, out, '');

const _xcode26 = {
  'xcode-select -p': '/Applications/Xcode.app/Contents/Developer\n',
  'plutil': '26.6\n',
};

ProcessRunner _xcode(String version, {String bridgeOut = 'glint-iossim 1\n'}) =>
    _runner({
      'xcode-select -p': _ok(_xcode26['xcode-select -p']!),
      'plutil': _ok('$version\n'),
      '/bridge version': _ok(bridgeOut),
    });

IosToolchain _toolchain(String? version,
        {bool found = true, bool allow = false, int? protocol = 1}) =>
    IosToolchain(
      xcode: XcodeInfo(version: version),
      bridge: BridgeLocation(
          '/bridge', found ? BridgeSource.build : BridgeSource.missing),
      bridgeProtocol: protocol,
      allowUntested: allow,
    );

void main() {
  group('detectXcode', () {
    test('reads the selected Xcode version from its Info.plist', () async {
      final calls = <String>[];
      final info = await detectXcode(
          run: _runner({
        'xcode-select -p': _ok(_xcode26['xcode-select -p']!),
        'plutil': _ok(_xcode26['plutil']!),
      }, calls: calls));
      expect(info.version, '26.6');
      expect(info.major, 26);
      expect(info.tested, isTrue);
      expect(calls.last, endsWith('/Applications/Xcode.app/Contents/Info.plist'));
    });

    test('Command Line Tools alone is reported, not a version', () async {
      final info = await detectXcode(
          run: _runner({
        'xcode-select -p': _ok('/Library/Developer/CommandLineTools\n'),
      }));
      expect(info.version, isNull);
      expect(info.error, contains('not an Xcode app'));
    });
  });

  group('bridgeHandshake', () {
    test('parses the protocol number', () async {
      final h = await bridgeHandshake('/bridge', run: _xcode('26.6'));
      expect(h.protocol, 1);
      expect(h.error, isNull);
    });

    test('a bridge without the version command is named as outdated', () async {
      final h = await bridgeHandshake('/bridge',
          run: _runner({'/bridge version': ProcessResult(0, 1, '', 'usage')}));
      expect(h.protocol, isNull);
      expect(h.error, contains('predates'));
    });
  });

  group('IosToolchain', () {
    test('a tested Xcode allows bridge actions without warnings', () {
      final t = _toolchain('26.6');
      expect(t.blocker, isNull);
      expect(t.warnings, isEmpty);
      expect(t.toJson(), {
        'xcode': '26.6',
        'bridge': 'build',
        'bridgeProtocol': 1,
        'actionsAllowed': true,
      });
    });

    test('an untested Xcode major blocks and says how to override', () {
      final t = _toolchain('28.0');
      expect(t.blocker, contains('Xcode 28.0 is untested'));
      expect(t.nextSteps.join(' '), contains('$allowUntestedXcodeEnv=true'));
      expect(t.toJson()['actionsAllowed'], isFalse);
    });

    test('the override lets it run with a warning', () {
      final t = _toolchain('28.0', allow: true);
      expect(t.blocker, isNull);
      expect(t.warnings.single, contains('may misbehave'));
    });

    test('an unreadable Xcode version warns but does not block', () {
      final t = IosToolchain(
          xcode: const XcodeInfo(error: 'xcode-select not found'),
          bridge: const BridgeLocation('/bridge', BridgeSource.build),
          bridgeProtocol: 1);
      expect(t.blocker, isNull);
      expect(t.warnings.single, contains('could not read the Xcode version'));
    });

    test('a missing bridge blocks with build steps', () {
      final t = _toolchain('26.6', found: false, protocol: null);
      expect(t.blocker, contains('not installed'));
      expect(t.nextSteps.first, contains('swift build -c release'));
    });

    test('a protocol mismatch warns', () {
      expect(_toolchain('26.6', protocol: 0).warnings.single,
          contains('bridge protocol 0, glint expects $expectedBridgeProtocol'));
    });
  });

  test('a blocked toolchain refuses bridge commands without running them', () async {
    final calls = <String>[];
    final backend = IosSimBackend(
      udid: 'U',
      deviceLogicalWidth: 400,
      deviceLogicalHeight: 800,
      devicePixelRatio: 2,
      binaryPath: '/bridge',
      toolchain: _toolchain('28.0'),
      run: (exe, args) async {
        calls.add(exe);
        return _ok('');
      },
    );
    await expectLater(backend.tap(physicalX: 10, physicalY: 10),
        throwsA(isA<IosToolchainBlocked>()));
    expect(calls, isEmpty);
  });

  test('a blocked action maps to unsupportedToolchain with nextSteps', () {
    final r = StructuredResponse.toolchainBlocked(
        IosToolchainBlocked('ios-sim', 'Xcode 28.0 is untested', ['switch']));
    expect(r.isError, isTrue);
    expect(r.data!['errorKind'], 'unsupportedToolchain');
    expect(r.nextSteps, ['switch']);
  });

  group('locateIosBridge', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('glint-bridge'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('explicit path, then the env var', () {
      expect(locateIosBridge('/x', env: {bridgePathEnv: '/y'}).source,
          BridgeSource.argument);
      final fromEnv = locateIosBridge(null,
          env: {bridgePathEnv: '/y'}, scriptPath: '${tmp.path}/bin/glint.dart');
      expect((fromEnv.path, fromEnv.source), ('/y', BridgeSource.env));
    });

    test('the newest build inside the package wins', () {
      final debug = File('${tmp.path}/$kDefaultBridgePath')..createSync(recursive: true);
      final release = File('${tmp.path}/$kReleaseBridgePath')..createSync(recursive: true);
      debug.setLastModifiedSync(DateTime(2026));
      release.setLastModifiedSync(DateTime(2025));
      final found = locateIosBridge(null,
          env: {'HOME': tmp.path}, scriptPath: '${tmp.path}/bin/glint.dart');
      expect((found.path, found.source), (debug.path, BridgeSource.build));
    });

    test('nothing built points at the versioned cache path', () {
      final found = locateIosBridge(null,
          env: {'HOME': tmp.path}, scriptPath: '${tmp.path}/bin/glint.dart');
      expect(found.source, BridgeSource.missing);
      expect(found.path, '${tmp.path}/.glint/bin/glint-iossim-$glintVersion');
    });
  });

  group('checkIosToolchain download', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('glint-home'));
    tearDown(() => home.deleteSync(recursive: true));

    final binary = 'fake bridge'.codeUnits;

    test('downloads, verifies and caches a missing bridge', () async {
      final fetched = <Uri>[];
      final t = await checkIosToolchain(null,
          env: {'HOME': home.path},
          run: _xcode('26.6'),
          fetch: (uri) async {
            fetched.add(uri);
            return uri.path.endsWith('.sha256')
                ? '${sha256.convert(binary)}  $bridgeAssetName\n'.codeUnits
                : binary;
          });
      final cached = File(cachedBridgePath(env: {'HOME': home.path}));
      expect(fetched.last, bridgeReleaseUri());
      expect(cached.readAsBytesSync(), binary);
      expect(cached.statSync().modeString(), startsWith('rwx'));
      expect(t.bridge.source, BridgeSource.cache);
    });

    test('a checksum mismatch keeps nothing and blocks with the reason', () async {
      final t = await checkIosToolchain(null,
          env: {'HOME': home.path},
          run: _xcode('26.6'),
          fetch: (uri) async =>
              uri.path.endsWith('.sha256') ? '${'0' * 64}\n'.codeUnits : binary);
      expect(File(cachedBridgePath(env: {'HOME': home.path})).existsSync(), isFalse);
      expect(t.blocker, contains('checksum mismatch'));
    });

    test('the opt-out skips the download', () async {
      final t = await checkIosToolchain(null,
          env: {'HOME': home.path, noBridgeDownloadEnv: 'true'},
          run: _xcode('26.6'),
          fetch: (_) => fail('must not fetch'));
      expect(t.blocker, contains(noBridgeDownloadEnv));
    });
  });

  test('glint and the Swift bridge agree on the protocol number', () {
    final swift = File('native/ios_sim_bridge/Sources/glint-iossim/main.swift')
        .readAsStringSync();
    final m = RegExp(r'let bridgeProtocol = (\d+)').firstMatch(swift);
    expect(int.parse(m!.group(1)!), expectedBridgeProtocol);
  });
}
