import 'dart:async';

import 'package:dart_mcp/server.dart' show CallToolRequest;
import 'package:glint/glint.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show Event;

/// A runtime that "attaches" instantly and never talks to a VM.
class _FakeRuntime implements FlutterRuntime {
  Uri? uri;
  bool attached = false;
  final _disconnect = StreamController<void>.broadcast();

  @override
  Future<void> attach(Uri vmServiceUri) async {
    uri = vmServiceUri;
    attached = true;
  }

  @override
  Future<void> disconnect() async => attached = false;

  @override
  bool get isAttached => attached;

  @override
  Stream<void> get onDisconnect => _disconnect.stream;

  @override
  Stream<Event> get stderrEvents => const Stream.empty();
  @override
  Stream<Event> get stdoutEvents => const Stream.empty();
  @override
  Stream<Event> get loggingEvents => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

AndroidDevice _device(String serial) =>
    AndroidDevice(serial: serial, adbPath: 'adb');

void main() {
  deviceGoneMain();
  group('GlintSession pool', () {
    late int created;
    late GlintSession session;

    setUp(() {
      created = 0;
      session = GlintSession(runtimeFactory: () {
        created++;
        return _FakeRuntime();
      });
    });

    tearDown(() => session.detachAll());

    test('attaching two apps pools both; the latest is active', () async {
      final a = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      a.displayName = 'Sanga Eats';
      final b = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:2/b=/'), device: _device('B'));
      b.displayName = 'AeTrust';
      expect(session.apps.length, 2);
      expect(session.active, same(b));
      expect(session.device.id, 'B');
      expect(created, 2);
    });

    test('re-attaching a pooled vmUri switches without reconnecting', () async {
      final a = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:2/b=/'), device: _device('B'));
      final again = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      expect(again, same(a));
      expect(session.active, same(a));
      expect(created, 2, reason: 'no new runtime for a live pooled app');
    });

    test('a new vmUri on the same device replaces the old entry', () async {
      await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:9/restarted=/'),
          device: _device('A'));
      expect(session.apps.length, 1);
      expect(session.active!.vmUri.toString(), 'http://127.0.0.1:9/restarted=/');
      expect(created, 2);
    });

    test('matchApps resolves ids, names, packages and prefixes', () async {
      final a = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      a
        ..displayName = 'Sanga Eats'
        ..package = 'sanga_mobile'
        ..deviceName = 'iPhone Air';
      final b = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:2/b=/'), device: _device('B'));
      b
        ..displayName = 'AeTrust'
        ..package = 'aetrust'
        ..deviceName = 'iPhone 17';
      expect(session.findApp('A'), same(a));
      expect(session.findApp('sanga eats'), same(a));
      expect(session.findApp('aetrust'), same(b));
      expect(session.findApp('iphone 1'), same(b));
      expect(session.findApp('iphone'), isNull, reason: 'ambiguous prefix');
      expect(session.matchApps('iphone').length, 2);
      expect(session.findApp('nope'), isNull);
    });

    test('withApp routes one call and restores the active app', () async {
      final a = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      final b = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:2/b=/'), device: _device('B'));
      expect(session.active, same(b));
      final seen = await session.withApp(a, () async => session.device.id);
      expect(seen, 'A');
      expect(session.active, same(b));
    });

    test('detaching the active app promotes the only remaining one', () async {
      await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:2/b=/'), device: _device('B'));
      await session.detach();
      expect(session.apps.length, 1);
      expect(session.active?.id, 'A');
      await session.detach(deviceId: 'A');
      expect(session.isAttached, isFalse);
    });

    test('the app arg routes a tool call and rejects unknown names', () async {
      final a = await session.attach(
          vmUri: Uri.parse('http://127.0.0.1:1/a=/'), device: _device('A'));
      a.displayName = 'Sanga Eats';
      final result = await const HardwareButtonTool().invoke(
        session,
        CallToolRequest(name: 'hardware_button', arguments: const {
          'button': 'home',
          'app': 'nobody',
        }),
      );
      final s = result.structuredContent as Map<String, Object?>;
      expect(s['errorKind'], 'unknownApp');
      expect((s['nextSteps'] as List).join(), contains('Sanga Eats'));
    });

    test('every routed tool schema carries the app property', () {
      for (final tool in kDefaultGlintTools) {
        final def = tool.registeredDefinition as Map<String, Object?>;
        final props = ((def['inputSchema'] as Map)['properties'] as Map);
        if (tool.routesByApp) {
          expect(props.containsKey('app'), isTrue, reason: tool.definition.name);
        }
      }
    });
  });
}

void deviceGoneMain() {
  test('deviceGoneResponse names the device and how to get it back', () async {
    final session = GlintSession();
    final app = AppSession.bindDevice(
        device: AndroidDevice(serial: 'emulator-5554', adbPath: 'adb'))
      ..displayName = 'AeTrust'
      ..deviceName = 'Pixel 8';
    final r = GlintTool.deviceGoneResponse(session, app);
    expect(r.isError, isTrue);
    expect(r.data?['errorKind'], 'deviceGone');
    expect(r.summary, contains('emulator Pixel 8'));
    expect(r.nextSteps.first, contains('attach device:"emulator-5554"'));
  });
}
