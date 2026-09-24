import 'package:glint/src/runtime/flutter_runtime.dart';
import 'package:glint/src/runtime/vm_service_runtime.dart';
import 'package:glint/src/vm/vm_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// Answers inspector calls only for [liveIsolate]; any other isolate id is collected.
class _Service implements VmService {
  String liveIsolate = 'isolates/new';
  final calls = <String?>[];

  @override
  Future<Response> callServiceExtension(String method,
      {String? isolateId, Map<String, dynamic>? args}) async {
    calls.add(isolateId);
    if (isolateId != liveIsolate) {
      throw SentinelException.parse(
          method, {'type': 'Sentinel', 'kind': 'Collected', 'valueAsString': '<collected>'});
    }
    return Response.parse({
      'type': '_extensionType',
      'result': {'description': 'RootWidget'},
    })!;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _Client extends VmClient {
  _Client(this.svc, {this.found = true});
  final _Service svc;
  final bool found;
  String isolate = 'isolates/old';
  int reselects = 0;

  @override
  VmService get service => svc;
  @override
  String get flutterIsolateId => isolate;
  @override
  Future<void> reselect() async {
    reselects++;
    if (!found) throw StateError('No isolate exposes ext.flutter.*');
    isolate = svc.liveIsolate;
  }
}

void main() {
  test('a collected isolate is re-selected and the call retried once', () async {
    final client = _Client(_Service());
    final rt = VmServiceRuntime(client: client);
    final tree = await rt.readWidgetTree(groupName: 'g');
    expect(tree['description'], 'RootWidget');
    expect(client.reselects, 1);
    expect(client.svc.calls, ['isolates/old', 'isolates/new']);
  });

  test('no new isolate after a restart reports the connection lost', () async {
    final rt = VmServiceRuntime(client: _Client(_Service(), found: false));
    expect(rt.readWidgetTree(groupName: 'g'),
        throwsA(isA<RuntimeConnectionLostError>()));
  });
}
