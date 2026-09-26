import 'dart:async';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Longest a caller waits on the VM to expand one value before settling for its preview.
const instanceTextTimeout = Duration(seconds: 2);

/// The WebSocket address of a VM service, `ws(s)://host:port/<token>/ws`, from any spelling of it.
String vmServiceWsUri(Uri uri) {
  if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri.toString();
  final segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isEmpty || segments.last != 'ws') segments.add('ws');
  return Uri(
    scheme: uri.scheme == 'https' ? 'wss' : 'ws',
    host: uri.host,
    port: uri.port,
    pathSegments: segments,
  ).toString();
}

/// One spelling per VM service, `http(s)://host:port/<auth token>/`: DTD lists `ws://…/ws`, `flutter run` prints `http://…/`, and both name the same VM.
String canonicalVmServiceUri(String raw) {
  final trimmed = raw.trim();
  final u = Uri.tryParse(trimmed);
  if (u == null || u.host.isEmpty) return trimmed;
  final scheme = switch (u.scheme) {
    'ws' => 'http',
    'wss' => 'https',
    final s => s,
  };
  final segments = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isNotEmpty && segments.last == 'ws') segments.removeLast();
  final path = segments.isEmpty ? '/' : '/${segments.join('/')}/';
  return '$scheme://${u.host}${u.hasPort ? ':${u.port}' : ''}$path';
}

/// Connects to the VM service at [uri] and checks it answers; a stale DDS that accepts the socket but never replies fails within [probeTimeout] with a StateError saying to restart the app.
Future<VmService> connectVmService(
  Uri uri, {
  Duration connectTimeout = const Duration(seconds: 8),
  Duration probeTimeout = const Duration(seconds: 5),
}) async {
  final pending = vmServiceConnectUri(vmServiceWsUri(uri));
  final VmService svc;
  try {
    svc = await pending.timeout(connectTimeout);
  } on TimeoutException {
    // A backgrounded or suspended app can leave the WebSocket upgrade unanswered; drop the socket if it ever opens.
    unawaited(pending.then((s) => s.dispose(), onError: (_) {}));
    rethrow;
  }
  try {
    await svc.getVersion().timeout(probeTimeout);
  } on Object {
    await svc.dispose().timeout(const Duration(seconds: 2), onTimeout: () {});
    throw StateError(
      'VM service at $uri accepted the connection but did not respond to '
      'getVersion() within ${probeTimeout.inSeconds}s. The DDS instance is likely '
      'stale; restart the Flutter app to spawn a fresh one.',
    );
  }
  return svc;
}

/// The full text of [ref]: a string cut at the VM's 128-char preview is refetched, a non-string object is asked for its toString(); null for a null ref. When the VM can't expand it, the preview comes back with a note saying how much was cut.
Future<String?> instanceText(VmService service, String? isolateId, InstanceRef? ref) async {
  if (ref == null || ref.kind == InstanceKind.kNull) return null;
  final preview = ref.valueAsString;
  final id = ref.id;
  final cut = ref.valueAsStringIsTruncated == true;
  if (isolateId != null && id != null) {
    try {
      if (ref.kind == InstanceKind.kString) {
        if (!cut) return preview;
        final full = await service
            .getObject(isolateId, id, offset: 0, count: ref.length)
            .timeout(instanceTextTimeout);
        if (full is Instance && full.valueAsString != null) return full.valueAsString;
      } else if (preview == null || cut) {
        final text =
            await service.invoke(isolateId, id, 'toString', const []).timeout(instanceTextTimeout);
        if (text is InstanceRef && text.kind == InstanceKind.kString) {
          return await instanceText(service, isolateId, text);
        }
      } else {
        return preview;
      }
    } on Object {
      // collected, timed out, or toString threw: fall back to the preview
    }
  }
  if (preview == null) return ref.classRef?.name;
  if (!cut) return preview;
  final total = ref.length;
  return '$preview… [cut by the VM at ${preview.length}${total == null ? '' : ' of $total'} chars]';
}
