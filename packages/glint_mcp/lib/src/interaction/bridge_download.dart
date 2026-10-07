import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../version.dart';

/// Env var that stops glint fetching the prebuilt bridge.
const String noBridgeDownloadEnv = 'GLINT_NO_BRIDGE_DOWNLOAD';

/// The release asset name of the universal macOS bridge.
const String bridgeAssetName = 'glint-iossim-macos';

/// The release asset name of glint's Android input server.
const String androidServerAssetName = 'glint-android-server.dex';

/// The bridge asset attached to this version's GitHub Release.
Uri bridgeReleaseUri([String version = glintVersion]) => releaseAssetUri(bridgeAssetName, version);

/// An asset attached to this version's GitHub Release.
Uri releaseAssetUri(String asset, [String version = glintVersion]) => Uri.parse(
    'https://github.com/Lukas-io/glint/releases/download/glint_mcp-v$version/$asset');

/// Fetches one URL's body; injected so tests run offline.
typedef BytesFetcher = Future<List<int>> Function(Uri uri);

class BridgeDownloadError implements Exception {
  BridgeDownloadError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads the release bridge to [dest], checks it against the published sha256, and marks it executable.
Future<void> downloadBridge(String dest,
    {BytesFetcher? fetch, void Function(String phase)? onPhase}) async {
  onPhase?.call('downloading the glint-iossim bridge for glint $glintVersion');
  await downloadReleaseAsset(bridgeAssetName, dest, executable: true, fetch: fetch);
}

/// Downloads release asset [asset] to [dest] and checks it against its published sha256; [executable] marks it runnable.
Future<void> downloadReleaseAsset(String asset, String dest,
    {bool executable = false, BytesFetcher? fetch}) async {
  final get = fetch ?? _httpGet;
  final uri = releaseAssetUri(asset);
  final expected = String.fromCharCodes(
          await get(Uri.parse('$uri.sha256')))
      .trim()
      .split(RegExp(r'\s+'))
      .first
      .toLowerCase();
  final bytes = await get(uri);
  final actual = sha256.convert(bytes).toString();
  if (actual != expected) {
    throw BridgeDownloadError(
        'checksum mismatch for $uri: expected $expected, got $actual');
  }
  final partial = File('$dest.partial-$pid');
  await partial.parent.create(recursive: true);
  await partial.writeAsBytes(bytes, flush: true);
  if (executable) {
    final chmod = await Process.run('chmod', ['755', partial.path]);
    if (chmod.exitCode != 0) {
      await partial.delete();
      throw BridgeDownloadError('chmod failed: ${chmod.stderr}');
    }
  }
  await partial.rename(dest);
}

Future<List<int>> _httpGet(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw BridgeDownloadError(response.statusCode == HttpStatus.notFound
          ? 'no prebuilt bridge for glint $glintVersion (404 at $uri)'
          : 'HTTP ${response.statusCode} from $uri');
    }
    final body = <int>[];
    await response
        .timeout(const Duration(seconds: 60))
        .forEach(body.addAll);
    return body;
  } on SocketException catch (e) {
    throw BridgeDownloadError('could not reach github.com: ${e.message}');
  } on TimeoutException {
    throw BridgeDownloadError('timed out downloading $uri');
  } finally {
    client.close(force: true);
  }
}
