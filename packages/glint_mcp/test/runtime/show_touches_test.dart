import 'dart:async';

import 'package:dart_mcp/server.dart' show CallToolRequest;
import 'package:glint_mcp/glint.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// A VM runtime with no VM: records the agent install and every agent call, and answers `touches` with [touchesReply].
class _AgentRuntime extends VmServiceRuntime {
  String isolate = 'isolates/1';
  String installReply = 'installed';
  Map<String, Object?> Function(bool on) touchesReply = (on) => {'on': on};
  final installs = <String>[];
  final calls = <Map<String, String>>[];
  bool attached = false;

  @override
  String get flutterIsolateId => isolate;
  @override
  bool get isAttached => attached;
  @override
  Future<void> attach(Uri vmServiceUri) async => attached = true;
  @override
  Future<void> disconnect() async => attached = false;
  @override
  Stream<Event> get extensionEvents => const Stream.empty();
  @override
  Stream<Event> get stderrEvents => const Stream.empty();
  @override
  Stream<Event> get stdoutEvents => const Stream.empty();
  @override
  Stream<Event> get loggingEvents => const Stream.empty();

  @override
  Future<InstanceRef> evaluateIn(String expression, {String? librarySuffix, Map<String, String>? scope}) async {
    installs.add(expression);
    return InstanceRef(
        kind: InstanceKind.kString,
        identityHashCode: 0,
        classRef: ClassRef(id: 'c', name: 'String'),
        id: 'i',
        valueAsString: installReply);
  }

  @override
  Future<Map<String, Object?>?> callExtensionOrNull(String method, Map<String, String> args,
      {Duration? timeout}) async {
    expect(method, kAgentExtension);
    calls.add(args);
    return switch (args['op']) {
      'touches' => touchesReply(args['on'] == 'true'),
      'lifecycle' => {'state': 'resumed'},
      _ => {'status': 'ok'},
    };
  }

  List<String?> get touchCalls => [
        for (final c in calls)
          if (c['op'] == 'touches') c['on']
      ];
}

void main() {
  group('agent source', () {
    late String source;

    setUpAll(() async {
      final rt = _AgentRuntime();
      await AppAgent.of(rt)!.call({'op': 'lifecycle'});
      source = rt.installs.single;
    });

    test('registers the extension glint calls and handles op touches', () {
      expect(source, contains("registerServiceExtension(name: '${kAgentExtension.split('.').last}'"));
      expect(source, contains("op == 'touches'"));
      expect(source, contains('RenderView.debugAddPaintCallback(paintTouches)'));
      expect(source, contains('RenderView.debugRemovePaintCallback(paintTouches)'));
      expect(source, contains('pointerRouter.addGlobalRoute(onPointer)'));
      expect(source, contains('pointerRouter.removeGlobalRoute(onPointer)'));
    });

    test('is sent as one line, so it cannot hold a line comment', () {
      expect(source, isNot(contains('\n')));
      expect(source, isNot(contains('//')));
    });

    test('touches only repaint: no widget, no rebuild for get_scene or settle to see', () {
      for (final builds in ['Overlay', 'setState', 'markNeedsBuild', 'scheduleBuildFor']) {
        expect(source, isNot(contains(builds)), reason: builds);
      }
      expect(source, contains('markNeedsPaint()'));
    });
  });

  group('AppAgent touches', () {
    test('setTouches sends op touches and remembers the setting', () async {
      final rt = _AgentRuntime();
      final agent = AppAgent.of(rt)!;
      expect(await agent.setTouches(true), {'on': true});
      expect(agent.showTouches, isTrue);
      expect(rt.touchCalls, ['true', 'true'], reason: 'the fresh install puts the setting back, then the call itself');
    });

    test('a hot restart reinstalls the agent and turns touches back on', () async {
      final rt = _AgentRuntime();
      final agent = AppAgent.of(rt)!;
      await agent.setTouches(true);
      rt.calls.clear();
      rt.isolate = 'isolates/2';
      await agent.call({'op': 'settle'});
      expect(rt.installs, hasLength(2));
      expect(rt.calls.map((c) => c['op']), ['touches', 'settle']);
      expect(rt.touchCalls, ['true']);
    });

    test('touches off: a fresh install sends nothing extra', () async {
      final rt = _AgentRuntime();
      await AppAgent.of(rt)!.call({'op': 'settle'});
      expect(rt.calls.map((c) => c['op']), ['settle']);
    });

    test('an agent left by an earlier glint is told touches are off', () async {
      final rt = _AgentRuntime()..installReply = 'present';
      await AppAgent.of(rt)!.call({'op': 'settle'});
      expect(rt.touchCalls, ['false']);
    });
  });

  group('AppSession.setShowTouches', () {
    Future<(AppSession, _AgentRuntime)> connect({bool showTouches = false}) async {
      final rt = _AgentRuntime();
      final app = await AppSession.connect(
        vmUri: Uri.parse('ws://127.0.0.1:1/x=/ws'),
        device: const AndroidDevice(serial: 'emulator-5554', route: InputRoute.app),
        runtimeFactory: () => rt,
        showTouches: showTouches,
      );
      return (app, rt);
    }

    test('on: the app draws touches', () async {
      final (app, rt) = await connect();
      final outcome = await app.setShowTouches(true);
      expect(outcome.failed, isFalse);
      expect(outcome.toJson(), {'on': true});
      expect(app.showTouches, isTrue);
      expect(rt.touchCalls.last, 'true');
    });

    test('a build without asserts is a branchable failure with a fix', () async {
      final (app, rt) = await connect();
      rt.touchesReply = (on) => {'on': false, 'reason': 'notDebug'};
      final outcome = await app.setShowTouches(true);
      expect(outcome.errorKind, GlintErrorKind.unsupportedBackendAction);
      expect(outcome.detail, contains('debug'));
      expect(outcome.nextSteps.single, contains('debug mode'));
    });

    test('device mode has no Flutter app to draw in', () async {
      final app = AppSession.bindDevice(device: const AndroidDevice(serial: 'emulator-5554'));
      final outcome = await app.setShowTouches(true);
      expect(outcome.errorKind, GlintErrorKind.flutterModeRequired);
      expect(outcome.nextSteps, isNotEmpty);
    });

    test('attaching with showTouches turns them on in the new isolate', () async {
      final (_, rt) = await connect(showTouches: true);
      expect(rt.touchCalls, ['true']);
    });

    test('detaching turns touches off so the app is left as it was', () async {
      final (app, rt) = await connect(showTouches: true);
      await app.dispose();
      expect(rt.touchCalls.last, 'false');
    });
  });

  group('config showTouches', () {
    Future<StructuredResponse> set(GlintSession session, Object value) => const ConfigTool().handle(
        session, CallToolRequest(name: 'config', arguments: {'op': 'set', 'key': 'showTouches', 'value': value}));

    test('with no app attached it is stored for the next attach', () async {
      final session = GlintSession();
      final r = await set(session, true);
      expect(r.isError, isFalse);
      expect(r.summary, contains('applies when one is'));
      expect(session.config.showTouches, isTrue);
    });

    test('applies to the attached app and says where touches are shown', () async {
      final rt = _AgentRuntime();
      final session = GlintSession(runtimeFactory: () => rt);
      await session.attach(
          vmUri: Uri.parse('ws://127.0.0.1:1/x=/ws'),
          device: const AndroidDevice(serial: 'emulator-5554', route: InputRoute.app));
      final r = await set(session, true);
      expect(r.isError, isFalse);
      expect(r.summary, contains('touches shown'));
      expect(r.data?['touches'], isA<Map<String, Object?>>());
      expect(rt.touchCalls.last, 'true');
      await session.detachAll();
    });

    test('an app that cannot draw them fails with errorKind, detail and nextSteps', () async {
      final rt = _AgentRuntime()..touchesReply = (on) => {'on': false, 'reason': 'notDebug'};
      final session = GlintSession(runtimeFactory: () => rt);
      await session.attach(
          vmUri: Uri.parse('ws://127.0.0.1:1/x=/ws'),
          device: const AndroidDevice(serial: 'emulator-5554', route: InputRoute.app));
      final r = await set(session, 'true');
      expect(r.isError, isTrue);
      expect(r.data?['errorKind'], 'unsupportedBackendAction');
      expect(r.data?['detail'], isNotNull);
      expect(r.nextSteps, isNotEmpty);
      await session.detachAll();
    });
  });
}
