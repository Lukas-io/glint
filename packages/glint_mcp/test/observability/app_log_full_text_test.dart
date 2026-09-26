import 'dart:async';

import 'package:glint_mcp/src/observability/app_log_buffer.dart';
import 'package:glint_mcp/src/runtime/flutter_runtime.dart';
import 'package:glint_core/glint_core.dart' show instanceText;
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

final _long = 'x' * 600;

InstanceRef _str(String id, String preview, {bool truncated = false, int? length}) =>
    InstanceRef(
      id: id,
      kind: InstanceKind.kString,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'String', library: null),
      valueAsString: preview,
      valueAsStringIsTruncated: truncated,
      length: length,
    );

InstanceRef _obj(String id, String className) => InstanceRef(
      id: id,
      kind: InstanceKind.kPlainInstance,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: className, library: null),
    );

/// Serves the full text of `long`, toString() of `err`, and a slow refetch for `slow`.
class _Service implements VmService {
  @override
  Future<Obj> getObject(String isolateId, String objectId,
      {int? offset, int? count, String? idZoneId}) async {
    if (objectId == 'slow') await Future<void>.delayed(const Duration(milliseconds: 50));
    return Instance(
      id: objectId,
      kind: InstanceKind.kString,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'String', library: null),
      valueAsString: objectId == 'slow' ? 'first-full' : _long,
    );
  }

  @override
  Future<Response> invoke(String isolateId, String targetId, String selector,
          List<String> argumentIds,
          {bool? disableBreakpoints, String? idZoneId}) async =>
      targetId == 'gone'
          ? throw SentinelException.parse('invoke', {'type': 'Sentinel', 'kind': 'Collected', 'valueAsString': '<collected>'})
          : _str('s', 'Bad state: boom');

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _Runtime implements FlutterRuntime {
  final logs = StreamController<Event>();
  @override
  VmService get rawService => _Service();
  @override
  Stream<Event> get loggingEvents => logs.stream;
  @override
  Stream<Event> get stderrEvents => const Stream.empty();
  @override
  Stream<Event> get stdoutEvents => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

Event _log(InstanceRef message, {InstanceRef? error}) => Event(
      kind: EventKind.kLogging,
      timestamp: 0,
      isolate: IsolateRef(id: 'iso', number: '1', name: 'main', isSystemIsolate: false),
      logRecord: LogRecord(
        message: message,
        level: 0,
        loggerName: _str('n', ''),
        error: error ?? InstanceRef(id: 'null', kind: InstanceKind.kNull, identityHashCode: 0, classRef: null),
        stackTrace: InstanceRef(id: 'null', kind: InstanceKind.kNull, identityHashCode: 0, classRef: null),
        sequenceNumber: 0,
        time: 0,
        zone: null,
      ),
    );

void main() {
  group('instanceText', () {
    final service = _Service();

    test('a truncated string is refetched whole', () async {
      final ref = _str('long', 'x' * 128, truncated: true, length: 600);
      expect(await instanceText(service, 'iso', ref), _long);
    });

    test('an object is asked for toString; a collected one falls back to its class', () async {
      expect(await instanceText(service, 'iso', _obj('err', 'StateError')), 'Bad state: boom');
      expect(await instanceText(service, 'iso', _obj('gone', 'StateError')), 'StateError');
    });
  });

  test('AppLogBuffer keeps long messages whole, adds the error, and keeps order', () async {
    final rt = _Runtime();
    final buffer = AppLogBuffer();
    await buffer.subscribe(rt);
    rt.logs.add(_log(_str('slow', 'first…', truncated: true, length: 10)));
    rt.logs.add(_log(_str('long', 'x' * 128, truncated: true, length: 600),
        error: _obj('err', 'StateError')));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final entries = buffer.query(limit: 10).toList();
    expect(entries.map((e) => e.content.split('\n').first),
        ['first-full', _long]);
    expect(entries.last.content, endsWith('error: Bad state: boom'));
  });
}
