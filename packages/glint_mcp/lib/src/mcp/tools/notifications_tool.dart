import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../interaction/image_size.dart';
import '../../notifications/android_notifications.dart';
import '../../notifications/ios_notifications.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';
import '../xctest_start.dart';

/// `notifications` — see and act on the system notifications of the attached app, as a user does from the shade.
class NotificationsTool extends GlintTool {
  const NotificationsTool();

  @override
  Tool get definition => Tool(
        name: 'notifications',
        description:
            'System notifications of the attached app. op: list (default; newest first, numbered), tap (opens it, then reports where the app landed), action (presses one of its buttons, e.g. Reply), clear (one by text/index, or all of the app\'s), send (a push payload), answer (allow or deny the system prompt asking to allow notifications). Pick one with text (matches title or body) or index from list. Android: everything but send, through the real shade. iOS simulator (glint starts its XCTest runner, building it on first use with progress): send through simctl, list, clear, answer, tap and action on a banner (buttons found with macOS OCR); an entry only in the Notification Center is shown again as a banner when glint sent it. errorKind: targetNotFound (no such notification or button), invalidArgument, unsupportedBackendAction, backendToolError.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(description: 'list (default) | tap | action | clear | send | answer'),
            'choice': Schema.string(description: 'answer: allow | deny, for the system prompt asking to allow notifications.'),
            'text': Schema.string(description: 'tap/action/clear: the notification whose title or body contains this.'),
            'index': Schema.int(description: 'tap/action/clear: its number in list (1 = newest).'),
            'action': Schema.string(description: 'action: the button label, e.g. Reply, Answer, Mark as read.'),
            'all': Schema.bool(description: 'list: every app\'s notifications, not only the attached app\'s. Default false.'),
            'title': Schema.string(description: 'send: alert title.'),
            'body': Schema.string(description: 'send: alert body.'),
            'category': Schema.string(description: 'send: aps.category, which picks the app\'s action buttons.'),
            'data': ObjectSchema(description: 'send: custom keys merged into the payload beside aps.'),
            'payload': ObjectSchema(description: 'send: the whole APNs payload instead of title/body/category/data.'),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'list';
    if (!const {'list', 'tap', 'action', 'clear', 'send', 'answer'}.contains(op)) {
      return _bad('unknown op "$op"', 'use list, tap, action, clear, send or answer');
    }
    final app = session.active;
    if (app == null) throw SessionNotAttachedError(missing: 'app');
    final dev = app.device;
    return switch (dev) {
      AndroidDevice() => op == 'send'
          ? StructuredResponse.error(
              summary: 'Android has no simulated push: a notification only comes from the app or its push server',
              errorKind: GlintErrorKind.unsupportedBackendAction,
              nextSteps: const ['trigger the app\'s own notification (the step that posts it, then background the app), then notifications op:list'],
            )
          : _android(session, dev, op, args),
      IosSimulator() => op == 'send' ? _send(dev.udid, app.bundleId, args, inFront: app.lastLifecycle == 'resumed' || app.lastLifecycle == 'inactive') : _ios(session, dev, op, args, request),
      _ => StructuredResponse.refuse(dev, Ability.notifications) ??
          StructuredResponse.error(summary: 'notifications are not available on ${dev.id}', errorKind: GlintErrorKind.notOnThisDevice),
    };
  }

  Future<StructuredResponse> _android(GlintSession session, AndroidDevice dev, String op, Map<String, Object?> args) async {
    final package = session.active!.bundleId ?? session.active!.package;
    final all = await _posted(dev);
    if (all == null) {
      return StructuredResponse.error(
        summary: 'dumpsys notification failed on ${dev.serial}',
        errorKind: GlintErrorKind.backendToolError,
        nextSteps: const ['check the device with adb devices, then retry'],
      );
    }
    final mine = [for (final n in all) if (package == null || n.package == package) n];
    if (op == 'answer') return _answerAndroid(session, dev, args);
    if (op == 'list') {
      final shown = (argBool(args, 'all') ?? false) ? all : mine;
      return StructuredResponse(
        summary: shown.isEmpty
            ? 'no notifications${package == null || shown == all ? '' : ' from $package'}'
            : [
                '${shown.length} notification(s)${shown == all ? '' : ' from $package'}, newest first:',
                for (final (i, n) in shown.indexed) '${i + 1}. ${shown == all ? '[${n.package}] ' : ''}${n.line}',
              ].join('\n'),
        data: {'notifications': [for (final n in shown) n.toJson()]},
        nextSteps: [if (shown.isNotEmpty) 'notifications op:tap index:1 opens the newest'],
      );
    }

    final pick = _pick(mine, args);
    if (op == 'clear' && pick.target == null && args['text'] == null && args['index'] == null) {
      return _clearAll(session, dev, package, mine.length);
    }
    if (pick.error != null) return pick.error!;
    final target = pick.target!;
    if (op == 'action') {
      final label = args['action'] as String?;
      if (label == null) return _bad('op:action needs action:"<button label>"', 'its buttons: ${target.actions.join(', ')}');
      if (!target.actions.any((a) => a.toLowerCase() == label.toLowerCase())) {
        return StructuredResponse.error(
          summary: '"${target.line}" has no "$label" button',
          errorKind: GlintErrorKind.targetNotFound,
          nextSteps: [target.actions.isEmpty ? 'it has no buttons; op:tap opens it' : 'its buttons: ${target.actions.join(', ')}'],
        );
      }
    }

    final row = await _shadeRow(session, dev, target, wantAction: op == 'action' ? args['action'] as String? : null);
    if (row.error != null) return row.error!;
    final r = row.row!;
    switch (op) {
      case 'tap':
        await session.backend.tap(physicalX: r.center.x, physicalY: r.bounds[1] + (r.bounds[3] - r.bounds[1]) ~/ 4);
        return _landed(session, 'tapped "${target.line}"', android: dev);
      case 'action':
        final label = args['action']! as String;
        final rect = r.actions.entries.firstWhere((e) => e.key.toLowerCase() == label.toLowerCase()).value;
        await session.backend.tap(physicalX: (rect[0] + rect[2]) ~/ 2, physicalY: (rect[1] + rect[3]) ~/ 2);
        return _landed(session, 'pressed "$label" on "${target.line}"', android: dev);
      default:
        await session.backend.swipe(
          physicalX1: r.center.x,
          physicalY1: r.center.y,
          physicalX2: r.bounds[2] + (r.bounds[2] - r.bounds[0]),
          physicalY2: r.center.y,
          durationMs: 250,
        );
        await _adb(dev, ['shell', 'cmd', 'statusbar', 'collapse']);
        final after = await _posted(dev) ?? const [];
        final gone = !after.any((n) => n.key == target.key);
        return gone
            ? StructuredResponse(summary: 'cleared "${target.line}"', data: {'cleared': 1})
            : StructuredResponse.error(
                summary: '"${target.line}" is still posted after the swipe',
                errorKind: GlintErrorKind.backendToolError,
                detail: target.ongoing ? 'it is ongoing, which a swipe does not clear' : null,
                nextSteps: const ['notifications op:list to see what remains'],
              );
    }
  }

  ({PostedNotification? target, StructuredResponse? error}) _pick(List<PostedNotification> mine, Map<String, Object?> args) {
    final index = argInt(args, 'index');
    final text = (args['text'] as String?)?.toLowerCase();
    if (mine.isEmpty) {
      return (
        target: null,
        error: StructuredResponse.error(
          summary: 'the app has no notifications',
          errorKind: GlintErrorKind.targetNotFound,
          nextSteps: const ['notifications op:list all:true shows every app\'s'],
        ),
      );
    }
    if (index != null) {
      if (index < 1 || index > mine.length) return (target: null, error: _bad('index must be 1-${mine.length}', 'notifications op:list numbers them'));
      return (target: mine[index - 1], error: null);
    }
    if (text == null) return (target: mine.length == 1 ? mine.single : null, error: mine.length == 1 ? null : _bad('${mine.length} notifications: pick one with text or index', 'notifications op:list numbers them'));
    final hits = [for (final n in mine) if ('${n.title ?? ''}\n${n.text ?? ''}'.toLowerCase().contains(text)) n];
    if (hits.length == 1) return (target: hits.single, error: null);
    return (
      target: null,
      error: StructuredResponse.error(
        summary: hits.isEmpty ? 'no notification mentions "$text"' : '${hits.length} notifications mention "$text"',
        errorKind: hits.isEmpty ? GlintErrorKind.targetNotFound : GlintErrorKind.invalidArgument,
        detail: [for (final (i, n) in mine.indexed) '${i + 1}. ${n.line}'].join('\n'),
        nextSteps: const ['pass index from the list above'],
      ),
    );
  }

  /// The on-screen windows from glint's server, or from `uiautomator dump` when the server is not running; null when neither answers.
  Future<Map<String, Object?>?> _windows(AndroidDevice dev) async {
    final server = dev.server;
    if (server != null && server.running) {
      try {
        return await server.call(const {'cmd': 'windows'});
      } on Object {
        // falls back to uiautomator below
      }
    }
    const path = '/data/local/tmp/glint_ui.xml';
    final dump = await _adb(dev, ['shell', 'uiautomator', 'dump', path]);
    if (dump.exitCode != 0) return null;
    final xml = await _adb(dev, ['exec-out', 'cat', path]);
    return xml.exitCode == 0 ? uiDumpAsWindows('${xml.stdout}') : null;
  }

  /// A group's summary row also carries its first child's title; the child itself is the smaller row.
  ShadeRow? _smallest(Iterable<ShadeRow> rows) {
    ShadeRow? best;
    int area(ShadeRow r) => (r.bounds[2] - r.bounds[0]) * (r.bounds[3] - r.bounds[1]);
    for (final r in rows) {
      if (best == null || area(r) < area(best)) best = r;
    }
    return best;
  }

  StructuredResponse _noWindows(AndroidDevice dev) => StructuredResponse.error(
        summary: 'the screen of ${dev.serial} could not be read: glint\'s device server is not running and uiautomator dump failed',
        errorKind: GlintErrorKind.backendToolError,
        detail: 'another automation tool may hold the accessibility connection',
        nextSteps: const ['stop other automation tools on the device, then attach again'],
      );

  /// Opens the shade and finds [target]'s row, expanding it when [wantAction] is folded away.
  Future<({ShadeRow? row, StructuredResponse? error})> _shadeRow(GlintSession session, AndroidDevice dev, PostedNotification target,
      {String? wantAction}) async {
    await _adb(dev, ['shell', 'cmd', 'statusbar', 'expand-notifications']);
    ShadeRow? row;
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final windows = await _windows(dev);
      if (windows == null) {
        await _adb(dev, ['shell', 'cmd', 'statusbar', 'collapse']);
        return (row: null, error: _noWindows(dev));
      }
      final shade = parseShade(windows);
      row = _smallest(shade.rows.where((r) => r.title == target.title && (target.text == null || (r.text ?? '').startsWith(target.text!.split('\n').first)))) ??
          _smallest(shade.rows.where((r) => r.title == target.title));
      if (row == null) continue;
      final want = wantAction?.toLowerCase();
      if (want == null || row.actions.keys.any((k) => k.toLowerCase() == want)) return (row: row, error: null);
      final expand = row.expand;
      if (expand == null) break;
      await session.backend.tap(physicalX: (expand[0] + expand[2]) ~/ 2, physicalY: (expand[1] + expand[3]) ~/ 2);
    }
    await _adb(dev, ['shell', 'cmd', 'statusbar', 'collapse']);
    return (
      row: null,
      error: StructuredResponse.error(
        summary: row == null
            ? '"${target.line}" is posted but its row was not found in the shade'
            : 'the shade shows "${target.line}" without a "$wantAction" button',
        errorKind: GlintErrorKind.targetNotFound,
        nextSteps: const ['device op:screenshot after expanding the shade shows what it draws'],
      ),
    );
  }

  Future<StructuredResponse> _clearAll(GlintSession session, AndroidDevice dev, String? package, int count) async {
    if (count == 0) return StructuredResponse(summary: 'nothing to clear', data: const {'cleared': 0});
    await _adb(dev, ['shell', 'cmd', 'statusbar', 'expand-notifications']);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final windows = await _windows(dev);
    if (windows == null) {
      await _adb(dev, ['shell', 'cmd', 'statusbar', 'collapse']);
      return _noWindows(dev);
    }
    final shade = parseShade(windows);
    final mineRows = [for (final r in shade.rows) r];
    for (final r in mineRows.reversed) {
      final posted = await _posted(dev) ?? const [];
      if (!posted.any((n) => n.package == package && n.title == r.title)) continue;
      await session.backend.swipe(
          physicalX1: r.center.x, physicalY1: r.center.y, physicalX2: r.bounds[2] * 2, physicalY2: r.center.y, durationMs: 250);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await _adb(dev, ['shell', 'cmd', 'statusbar', 'collapse']);
    final left = [for (final n in await _posted(dev) ?? const <PostedNotification>[]) if (n.package == package && !n.ongoing) n];
    return left.isEmpty
        ? StructuredResponse(summary: 'cleared $count notification(s) from $package', data: {'cleared': count})
        : StructuredResponse.error(
            summary: '${left.length} of the app\'s notifications are still posted',
            errorKind: GlintErrorKind.backendToolError,
            detail: left.map((n) => n.line).join('\n'),
            nextSteps: const ['notifications op:clear text:"…" for each one'],
          );
  }

  /// Waits for the app to come to the front after a notification opened it, and says where it landed.
  Future<StructuredResponse> _landed(GlintSession session, String did, {AndroidDevice? android}) async {
    String? lifecycle;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        lifecycle = await session.lifecycleState().timeout(const Duration(seconds: 1));
      } on Object {
        lifecycle = null;
      }
      if (lifecycle == 'resumed') break;
    }
    if (lifecycle != 'resumed') {
      if (android != null) await _adb(android, ['shell', 'cmd', 'statusbar', 'collapse']);
      return StructuredResponse(
        summary: '$did; the app did not come to the front (lifecycle: ${lifecycle ?? 'unknown'})',
        warnings: const ['the notification may run its action in the background, or open another app'],
        data: {'lifecycle': lifecycle},
        nextSteps: const ['device op:screenshot to see what is in front'],
      );
    }
    await session.settleDetector.awaitSettle(ceilingMs: 2000, quietFramesNeeded: 2, checkLoadingAffordances: false);
    final route = await session.withScene((s) async => s.routeStack.isEmpty ? null : s.routeStack.first.name, detail: SceneDetail.structural);
    return StructuredResponse(
      summary: '$did; ${session.active!.label} is in front${route == null ? '' : ' at $route'}',
      data: {'lifecycle': lifecycle, if (route != null) 'route': route},
      nextSteps: const ['get_scene to read the screen it opened'],
    );
  }

  Future<List<PostedNotification>?> _posted(AndroidDevice dev) async {
    final r = await _adb(dev, ['shell', 'dumpsys', 'notification', '--noredact']);
    if (r.exitCode != 0) return null;
    return [for (final n in parseNotificationDump('${r.stdout}')) if (n.title != null || n.text != null) n];
  }

  Future<ProcessResult> _adb(AndroidDevice dev, List<String> args) => Process.run(dev.adbPath, ['-s', dev.serial, ...args]);

  Future<StructuredResponse> _send(String udid, String? bundleId, Map<String, Object?> args, {required bool inFront}) async {
    if (bundleId == null) return _bad('the attached app\'s bundle id is unknown', 'attach again');
    final raw = args['payload'];
    final title = args['title'] as String?;
    final body = args['body'] as String?;
    if (raw == null && title == null && body == null) return _bad('op:send needs title and/or body, or payload', 'notifications op:send title:"Amara" body:"Got it"');
    final payload = raw is Map
        ? raw.cast<String, Object?>()
        : {
            ...?(args['data'] as Map?)?.cast<String, Object?>(),
            'aps': {
              'alert': {if (title != null) 'title': title, if (body != null) 'body': body},
              'sound': 'default',
              if (args['category'] != null) 'category': args['category'],
            },
          };
    if (payload['aps'] is! Map) return _bad('payload needs an aps object', 'see Apple\'s APNs payload keys');
    final file = File('${Directory.systemTemp.path}/glint-push-${DateTime.now().millisecondsSinceEpoch}.json')..writeAsStringSync(jsonEncode(payload));
    final r = await Process.run('xcrun', ['simctl', 'push', udid, bundleId, file.path]);
    if (r.exitCode == 0) (_sentPushes[udid] ??= []).add(payload);
    if (r.exitCode != 0) {
      return StructuredResponse.error(
        summary: 'simctl push failed',
        errorKind: GlintErrorKind.backendToolError,
        detail: '${r.stderr}'.trim(),
        nextSteps: const ['check the app is installed on this simulator and allowed to show notifications'],
      );
    }
    return StructuredResponse(
      summary: 'pushed to $bundleId on $udid${title == null ? '' : ': $title'}${body == null ? '' : ' · $body'}',
      data: {'payload': payload},
      warnings: [
        inFront
            ? 'the app was in front a moment ago, so iOS hands the push to the app rather than showing a banner; to test the banner, hardware_button home, wait a second, then send'
            : 'it shows as a banner for about 5 s, and only if the app was allowed to send notifications',
      ],
      nextSteps: [inFront ? 'get_scene to see how the app handled it' : 'notifications op:tap now opens it from the banner'],
    );
  }

  Future<StructuredResponse> _ios(
      GlintSession session, IosSimulator dev, String op, Map<String, Object?> args, CallToolRequest request) async {
    final got = await xcTestRunnerFor(session, dev, request);
    if (got.error != null) return got.error!;
    final runner = got.runner!;
    final token = request.meta?.progressToken;
    final notifier = session.progressNotifier;
    final began = DateTime.now();
    var phase = 'reading SpringBoard';
    final ticker = token == null || notifier == null
        ? null
        : Timer.periodic(const Duration(seconds: 15), (_) {
            final sec = DateTime.now().difference(began).inSeconds;
            notifier(ProgressNotification(progressToken: token, progress: sec, message: '$phase (${sec}s)'));
          });
    try {
      return await _iosOp(session, dev, op, args, runner, (p) => phase = p);
    } finally {
      ticker?.cancel();
    }
  }

  Future<StructuredResponse> _iosOp(GlintSession session, IosSimulator dev, String op, Map<String, Object?> args,
      XcTestRunner runner, void Function(String) onPhase) async {
    Future<Map<String, Object?>> tree() =>
        runner.call('GET', '/tree?app=com.apple.springboard', timeout: const Duration(seconds: 20));
    Future<void> touch(String path, Map<String, Object?> body, [int settleMs = 700]) async {
      await runner.call('POST', path, body: body);
      await Future<void>.delayed(Duration(milliseconds: settleMs));
    }

    final w = dev.logicalWidth, h = dev.logicalHeight;
    Future<void> openCenter() async {
      onPhase('opening the Notification Center');
      for (final b in parseSpringboardNotifications(await tree()).where((n) => n.frame[1] < h * 0.2)) {
        await touch('/swipe', {'x1': b.center.x, 'y1': b.center.y, 'x2': b.center.x, 'y2': 2}, 500);
      }
      await touch('/swipe', {'x1': w * 0.3, 'y1': 3, 'x2': w * 0.3, 'y2': h * 0.7}, 1200);
    }
    Future<void> closeCenter() => touch('/swipe', {'x1': w / 2, 'y1': h - 6, 'x2': w / 2, 'y2': h * 0.25});
    Future<void> tapAt(({double x, double y}) p) => touch('/tap', {'x': p.x, 'y': p.y});

    if (op == 'answer') {
      final choice = args['choice'] as String?;
      if (choice != 'allow' && choice != 'deny') return _bad('op:answer needs choice: allow | deny', 'notifications op:answer choice:allow');
      final t = await tree();
      final alert = springboardAlert(t);
      if (alert == null || !alert.contains('Notifications')) {
        return StructuredResponse.error(
          summary: alert == null ? 'no system prompt is showing' : 'the prompt showing is not about notifications: "$alert"',
          errorKind: GlintErrorKind.targetNotFound,
          nextSteps: const ['the app asks when it first requests permission; trigger that step first'],
        );
      }
      final want = choice == 'allow' ? 'allow' : 'don’t allow';
      final button = springboardButtons(t).where((b) => b.label.toLowerCase().replaceAll("'", '’') == want).firstOrNull;
      if (button == null) {
        return StructuredResponse.error(summary: 'the prompt has no "$want" button', errorKind: GlintErrorKind.targetNotFound,
            detail: springboardButtons(t).map((b) => b.label).join(', '), nextSteps: const ['device op:screenshot to see the prompt']);
      }
      await tapAt((x: button.frame[0] + button.frame[2] / 2, y: button.frame[1] + button.frame[3] / 2));
      final still = springboardAlert(await tree());
      return still == alert
          ? StructuredResponse.error(summary: 'the prompt is still showing after tapping ${button.label}', errorKind: GlintErrorKind.backendToolError, nextSteps: const ['retry once; if it stays, ask the user to tap it'])
          : StructuredResponse(summary: 'answered "$alert": ${button.label}', data: {'choice': choice});
    }

    final name = (session.active!.displayName ?? '').toLowerCase();
    final everyApp = argBool(args, 'all') ?? false;
    bool ours(ShownNotification n) => everyApp || name.isEmpty || n.app.toLowerCase() == name;
    final banners = [for (final n in parseSpringboardNotifications(await tree())) if (ours(n)) n];

    if (op == 'tap' || op == 'action') {
      final action = args['action'] as String?;
      if (op == 'action' && action == null) return _bad('op:action needs action:"<button label>"', 'e.g. action:"Reply"');
      var banner = banners.isEmpty ? null : _pickShown(banners, args).target;
      var again = false;
      if (banner == null) {
        await openCenter();
        final listed = await _centerCells(tree, tapAt, ours);
        final inCenter = _pickShown(listed, args);
        if (inCenter.target == null) {
          await closeCenter();
          return inCenter.error!;
        }
        final target = inCenter.target!;
        final payload = _sentPayload(dev.udid, target);
        if (payload == null) {
          await closeCenter();
          return StructuredResponse.error(
            summary: '"${target.line}" is only in the Notification Center, and the simulator does not open an entry there',
            errorKind: GlintErrorKind.unsupportedBackendAction,
            detail: 'a tap, the Open action and an unlock all leave the app suspended while the cover sheet is up; glint can replay only pushes it sent itself, and it did not send this one',
            nextSteps: const ['trigger the notification again, then op:tap or op:action while its banner shows (about 5 s)'],
          );
        }
        onPhase('showing "${target.line}" again as a banner');
        await _clearIos([target], tree, touch, closeCenter, everyApp: true, name: name);
        await _push(dev.udid, session.active!.bundleId!, payload);
        banner = await _awaitBanner(tree, target.line);
        again = true;
        if (banner == null) {
          return StructuredResponse.error(
            summary: 'the replayed push for "${target.line}" never showed as a banner',
            errorKind: GlintErrorKind.backendToolError,
            nextSteps: const ['check the app is in the background (hardware_button home), then retry'],
          );
        }
      }
      final note = again ? ' (sent again: the simulator opens banners, not Notification Center entries)' : '';
      if (action == null) {
        await tapAt(banner.center);
        return _landed(session, 'tapped the banner "${banner.line}"$note');
      }
      return _bannerAction(session, dev, banner, action, note, tree, touch, tapAt);
    }

    await openCenter();
    final cells = await _centerCells(tree, tapAt, ours);
    final shown = cells;

    if (op == 'list') {
      await closeCenter();
      return StructuredResponse(
        summary: shown.isEmpty
            ? 'no notifications${everyApp ? '' : ' from ${session.active!.label}'} in banners or the Notification Center'
            : [
                '${shown.length} notification(s)${everyApp ? '' : ' from ${session.active!.label}'}, newest first:',
                for (final (i, n) in shown.indexed) '${i + 1}. ${everyApp ? '[${n.app}] ' : ''}${n.line}',
              ].join('\n'),
        data: {'notifications': [for (final n in shown) n.toJson()]},
        nextSteps: [if (shown.isNotEmpty) 'op:tap or op:action with text or index acts on one'],
      );
    }

    if (args['text'] == null && args['index'] == null) {
      if (cells.isEmpty) {
        await closeCenter();
        return StructuredResponse(summary: 'nothing to clear', data: const {'cleared': 0});
      }
      onPhase('clearing ${cells.length} notification(s)');
      return _clearIos(cells, tree, touch, closeCenter, everyApp: everyApp, name: name);
    }
    final pick = _pickShown(cells, args);
    if (pick.error != null) {
      await closeCenter();
      return pick.error!;
    }
    return _clearIos([pick.target!], tree, touch, closeCenter, everyApp: true, name: name);
  }

  /// The app's Notification Center cells, expanding its stack first so every notification is listed.
  Future<List<ShownNotification>> _centerCells(Future<Map<String, Object?>> Function() tree,
      Future<void> Function(({double x, double y})) tapAt, bool Function(ShownNotification) ours) async {
    var cells = [for (final n in parseSpringboardNotifications(await tree())) if (ours(n)) n];
    final stack = cells.where((n) => n.grouped).firstOrNull;
    if (stack == null) return cells;
    await tapAt(stack.center);
    for (var i = 0; i < 3; i++) {
      cells = [for (final n in parseSpringboardNotifications(await tree())) if (ours(n)) n];
      if (!cells.any((n) => n.grouped)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return cells;
  }


  /// Pushes glint sent, per simulator, so an entry only in the Notification Center can be shown again as a banner.
  static final _sentPushes = <String, List<Map<String, Object?>>>{};

  Map<String, Object?>? _sentPayload(String udid, ShownNotification n) {
    for (final p in (_sentPushes[udid] ?? const <Map<String, Object?>>[]).reversed) {
      final alert = ((p['aps'] as Map?)?['alert']);
      final title = alert is Map ? alert['title'] as String? : null;
      final body = alert is Map ? alert['body'] as String? : alert as String?;
      if (title == n.title && body == n.body) return p;
    }
    return null;
  }

  Future<ProcessResult> _push(String udid, String bundleId, Map<String, Object?> payload) {
    final file = File('${Directory.systemTemp.path}/glint-push-${DateTime.now().millisecondsSinceEpoch}.json')..writeAsStringSync(jsonEncode(payload));
    return Process.run('xcrun', ['simctl', 'push', udid, bundleId, file.path]);
  }

  /// The banner showing [line], polled for up to 4 s.
  Future<ShownNotification?> _awaitBanner(Future<Map<String, Object?>> Function() tree, String line) async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final hit = parseSpringboardNotifications(await tree()).where((n) => n.line == line && n.frame[1] < 200).firstOrNull;
      if (hit != null) return hit;
    }
    return null;
  }

  /// Pulls the banner down to show its buttons, finds [action] on a screenshot with macOS Vision (the menu is outside the accessibility tree), and taps it.
  Future<StructuredResponse> _bannerAction(
    GlintSession session,
    IosSimulator dev,
    ShownNotification banner,
    String action,
    String note,
    Future<Map<String, Object?>> Function() tree,
    Future<void> Function(String, Map<String, Object?>, [int]) touch,
    Future<void> Function(({double x, double y})) tapAt,
  ) async {
    Future<List<OcrLine>?> screenText(String tag) async {
      final shot = '${Directory.systemTemp.path}/glint-notification-$tag-${DateTime.now().millisecondsSinceEpoch}.png';
      final cap = await Process.run('xcrun', ['simctl', 'io', dev.udid, 'screenshot', shot]);
      return cap.exitCode == 0 ? await readText(shot) : null;
    }

    final List<OcrLine> before;
    try {
      before = await screenText('before') ?? const [];
    } on OcrError catch (e) {
      return StructuredResponse.error(summary: e.message, errorKind: GlintErrorKind.unsupportedToolchain, detail: e.detail,
          nextSteps: const ['install the Xcode command line tools (xcode-select --install) so glint can build its OCR helper']);
    }
    await touch('/swipe', {'x1': banner.center.x, 'y1': banner.center.y, 'x2': banner.center.x, 'y2': banner.center.y + 300}, 1000);
    final expanded = parseSpringboardNotifications(await tree()).where((n) => n.line == banner.line).firstOrNull ?? banner;
    final menuTop = expanded.frame[1] + expanded.frame[3];
    final shot = '${Directory.systemTemp.path}/glint-notification-${DateTime.now().millisecondsSinceEpoch}.png';
    final cap = await Process.run('xcrun', ['simctl', 'io', dev.udid, 'screenshot', shot]);
    final size = cap.exitCode == 0 ? pngSize(shot) : null;
    if (size == null) return StructuredResponse.error(summary: 'could not screenshot the simulator', errorKind: GlintErrorKind.backendToolError, detail: '${cap.stderr}'.trim());
    final scale = size.$1 / dev.logicalWidth;
    final List<OcrLine> lines;
    try {
      lines = await readText(shot);
    } on OcrError catch (e) {
      await tapAt((x: dev.logicalWidth / 2, y: dev.logicalHeight * 0.92));
      return StructuredResponse.error(summary: e.message, errorKind: GlintErrorKind.unsupportedToolchain, detail: e.detail,
          nextSteps: const ['install the Xcode command line tools (xcode-select --install) so glint can build its OCR helper']);
    }
    bool background(OcrLine l) {
      final t = l.text.trim().toLowerCase();
      return before.any((b) {
        final o = b.text.trim().toLowerCase();
        return (o.contains(t) || t.contains(o)) && (b.y - l.y).abs() < 40 * scale && ((b.x + b.w / 2) - (l.x + l.w / 2)).abs() < 60 * scale;
      });
    }
    final below = [
      for (final l in lines)
        if (l.y / scale > menuTop - 4 && !background(l)) (text: l.text.trim(), x: (l.x + l.w / 2) / scale, y: (l.y + l.h / 2) / scale),
    ]..sort((a, b) => a.y.compareTo(b.y));
    final menu = <({String text, double x, double y})>[];
    for (final l in below) {
      if (menu.isNotEmpty && l.y - menu.last.y > 60) break;
      menu.add(l);
    }
    final hit = menu.where((m) => m.text.toLowerCase() == action.toLowerCase()).firstOrNull;
    if (hit == null) {
      await tapAt((x: dev.logicalWidth / 2, y: dev.logicalHeight * 0.92));
      return StructuredResponse.error(
        summary: 'the banner "${banner.line}" shows no "$action" button',
        errorKind: GlintErrorKind.targetNotFound,
        detail: menu.isEmpty ? 'no text showed under the banner after pulling it down' : 'text under the banner: ${menu.map((m) => '"${m.text}"').join(', ')}',
        nextSteps: const ['pass one of those labels as action; the app sets them through the notification category'],
      );
    }
    await tapAt((x: hit.x, y: hit.y));
    return _landed(session, 'pressed "${hit.text}" on the banner "${banner.line}"$note');
  }

  /// Clears [cells] one by one, swiping each away (and pressing Clear when the swipe only reveals it); counts what the Notification Center no longer shows.
  Future<StructuredResponse> _clearIos(
    List<ShownNotification> cells,
    Future<Map<String, Object?>> Function() tree,
    Future<void> Function(String, Map<String, Object?>, [int]) touch,
    Future<void> Function() closeCenter, {
    required bool everyApp,
    required String name,
  }) async {
    for (final cell in cells) {
      var now = parseSpringboardNotifications(await tree());
      final stack = now.where((n) => n.grouped).firstOrNull;
      if (stack != null && !now.any((n) => n.line == cell.line && !n.grouped)) {
        await touch('/tap', {'x': stack.center.x, 'y': stack.center.y});
        now = parseSpringboardNotifications(await tree());
      }
      final live = [for (final n in now) if (n.line == cell.line && !n.grouped) n].firstOrNull;
      if (live == null) continue;
      final f = live.frame;
      await touch('/swipe', {'x1': f[0] + f[2] - 20, 'y1': live.center.y, 'x2': f[0] + 40, 'y2': live.center.y});
      final after = await tree();
      if (!parseSpringboardNotifications(after).any((n) => n.line == cell.line)) continue;
      final clear = springboardButtons(after).where((b) => b.label == 'Clear' && (b.frame[1] - f[1]).abs() < f[3]).firstOrNull;
      if (clear != null) await touch('/tap', {'x': clear.frame[0] + clear.frame[2] / 2, 'y': clear.frame[1] + clear.frame[3] / 2});
    }
    var remaining = parseSpringboardNotifications(await tree());
    final restack = remaining.where((n) => n.grouped).firstOrNull;
    if (restack != null) {
      await touch('/tap', {'x': restack.center.x, 'y': restack.center.y});
      remaining = parseSpringboardNotifications(await tree());
    }
    final left = [for (final c in cells) if (remaining.any((n) => n.line == c.line)) c];
    await closeCenter();
    final cleared = cells.length - left.length;
    return left.isEmpty
        ? StructuredResponse(summary: 'cleared $cleared notification(s)', data: {'cleared': cleared})
        : StructuredResponse.error(
            summary: '${left.length} of ${cells.length} notification(s) are still in the Notification Center',
            errorKind: GlintErrorKind.backendToolError,
            detail: left.map((n) => n.line).join('\n'),
            nextSteps: const ['notifications op:list, then clear the rest one by one'],
          );
  }

  ({ShownNotification? target, StructuredResponse? error}) _pickShown(List<ShownNotification> shown, Map<String, Object?> args) {
    final index = argInt(args, 'index');
    final text = (args['text'] as String?)?.toLowerCase();
    if (shown.isEmpty) {
      return (target: null, error: StructuredResponse.error(summary: 'no notifications from the app in banners or the Notification Center', errorKind: GlintErrorKind.targetNotFound, nextSteps: const ['notifications op:list all:true shows every app\'s']));
    }
    if (index != null) {
      if (index < 1 || index > shown.length) return (target: null, error: _bad('index must be 1-${shown.length}', 'notifications op:list numbers them'));
      return (target: shown[index - 1], error: null);
    }
    if (text == null) {
      return shown.length == 1 ? (target: shown.single, error: null) : (target: null, error: _bad('${shown.length} notifications: pick one with text or index', 'notifications op:list numbers them'));
    }
    final hits = [for (final n in shown) if (n.line.toLowerCase().contains(text)) n];
    if (hits.length == 1) return (target: hits.single, error: null);
    return (
      target: null,
      error: StructuredResponse.error(
        summary: hits.isEmpty ? 'no notification mentions "$text"' : '${hits.length} notifications mention "$text"',
        errorKind: hits.isEmpty ? GlintErrorKind.targetNotFound : GlintErrorKind.invalidArgument,
        detail: [for (final (i, n) in shown.indexed) '${i + 1}. ${n.line}'].join('\n'),
        nextSteps: const ['pass index from the list above'],
      ),
    );
  }

  /// Taps Allow or Don't allow on Android's notification permission dialog.
  Future<StructuredResponse> _answerAndroid(GlintSession session, AndroidDevice dev, Map<String, Object?> args) async {
    final choice = args['choice'] as String?;
    if (choice != 'allow' && choice != 'deny') return _bad('op:answer needs choice: allow | deny', 'notifications op:answer choice:allow');
    final windows = await _windows(dev);
    if (windows == null) return _noWindows(dev);
    final want = choice == 'allow' ? 'allow' : 'don’t allow';
    final buttons = permissionButtons(windows);
    final b = buttons.where((b) => b.label.toLowerCase().replaceAll("'", '’') == want).firstOrNull;
    if (b == null) {
      return StructuredResponse.error(
        summary: buttons.isEmpty ? 'no permission dialog is showing' : 'the dialog has no "$want" button',
        errorKind: GlintErrorKind.targetNotFound,
        detail: buttons.isEmpty ? null : buttons.map((b) => b.label).join(', '),
        nextSteps: const ['device op:privacy service:notifications action:grant sets it without the dialog'],
      );
    }
    await session.backend.tap(physicalX: (b.bounds[0] + b.bounds[2]) ~/ 2, physicalY: (b.bounds[1] + b.bounds[3]) ~/ 2);
    return StructuredResponse(summary: 'answered the notification permission dialog: ${b.label}', data: {'choice': choice});
  }

  StructuredResponse _bad(String summary, String next) =>
      StructuredResponse.error(summary: summary, errorKind: GlintErrorKind.invalidArgument, nextSteps: [next]);
}
