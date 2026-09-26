import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Longest glint waits on the VM to expand one value before settling for its preview.
const instanceTextTimeout = Duration(seconds: 2);

/// The full text of [ref]: a string cut at the VM's 128-char preview is refetched, and a non-string object is asked for its toString(); null for a null ref.
Future<String?> instanceText(
    VmService service, String isolateId, InstanceRef? ref) async {
  if (ref == null || ref.kind == InstanceKind.kNull) return null;
  final preview = ref.valueAsString;
  final id = ref.id;
  try {
    if (ref.kind == InstanceKind.kString) {
      if (ref.valueAsStringIsTruncated != true || id == null) return preview;
      final full = await service
          .getObject(isolateId, id, offset: 0, count: ref.length)
          .timeout(instanceTextTimeout);
      return full is Instance ? full.valueAsString ?? preview : preview;
    }
    if (preview != null && ref.valueAsStringIsTruncated != true) return preview;
    if (id == null) return preview ?? ref.classRef?.name;
    final text = await service
        .invoke(isolateId, id, 'toString', const [])
        .timeout(instanceTextTimeout);
    if (text is InstanceRef && text.kind == InstanceKind.kString) {
      return await instanceText(service, isolateId, text);
    }
  } on Object {
    // collected, timed out, or toString threw: the preview is the best left
  }
  return preview ?? ref.classRef?.name;
}
