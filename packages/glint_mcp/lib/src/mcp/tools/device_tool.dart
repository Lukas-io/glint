import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../media/android_privacy.dart';
import '../../media/gallery.dart' show MediaDevice;
import '../../media/permissions.dart' show PermissionRefused, PermissionUnsupported;
import '../envelope.dart';
import '../screenshot.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// `device` — inspect or configure an iOS simulator. Defaults to the attached
/// device; pass `udid` to target another booted sim. ops: status (default) |
/// appearance | openurl | screenshot | privacy. Heavier control (location,
/// biometrics, push, status-bar) is roadmapped.
class DeviceTool extends GlintTool {
  const DeviceTool();

  @override
  Tool get definition => Tool(
        name: 'device',
        description:
            'Inspect or configure an iOS simulator: the attached one, or udid. op: status (default), appearance, openurl, screenshot (PNG, works headless; crop with glintId or region, several apps side by side with apps), privacy, biometric; each argument names the ops it serves. On Android (udid: an adb serial) op:privacy sets runtime permissions and screen-capture consent. errorKind: invalidArgument, targetNotFound, backendToolError (simctl failed), unsupportedBackendAction.',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description: 'status (default) | appearance | openurl | screenshot | '
                  'privacy | biometric | network (physical iPhone: value list | off | <profile>)',
            ),
            'udid': Schema.string(
              description: 'Target simulator UDID. Defaults to the attached device.',
            ),
            'inline': Schema.bool(
              description: 'op=screenshot: also return the image as image '
                  'content, so no separate read is needed. Default false, true with glintId, region or apps.',
            ),
            'maxSize': Schema.int(
              description: 'op=screenshot inline: longest side in pixels of the '
                  'image sent (0 = full size); with apps, each device\'s height. Default: 720 for crops and side by side, else the screenshotMaxSize config (1024).',
            ),
            'glintId': Schema.string(
              description: 'screenshot: crop to this widget, with a little margin. Sent inline, small.',
            ),
            'region': ObjectSchema(
              description:
                  'screenshot: crop to {top, bottom, left, right}, fractions 0-1 of the screen (missing sides default to the edges). Sent inline, small.',
              properties: {
                'top': Schema.num(),
                'bottom': Schema.num(),
                'left': Schema.num(),
                'right': Schema.num(),
              },
            ),
            'apps': Schema.list(
              items: Schema.string(),
              description:
                  'screenshot: several attached apps (name, package or device) in one image, side by side, left to right in this order.',
            ),
            'afterMs': Schema.int(
              description: 'screenshot: wait this long first, 0-30000.',
            ),
            'waitFor': Schema.string(
              description: 'screenshot: first wait (up to 15 s) until the app (the first of apps) shows this text.',
            ),
            'latest': Schema.bool(
              description: 'screenshot only: return the newest background capture '
                  '(taken when the app left the foreground) instead of taking '
                  'a new one. Default false.',
            ),
            'value': Schema.string(
              description: 'appearance: light|dark. openurl: the URL.',
            ),
            'action': Schema.string(
              description: 'privacy: grant | revoke | reset. biometric: '
                  'enrol | unenrol | match | nomatch (match/nomatch answer a '
                  'Face ID / Touch ID prompt that is showing).',
            ),
            'type': Schema.string(
              description: 'biometric: face (default) | touch.',
            ),
            'service': Schema.string(
              description:
                  'privacy: a simctl service: photos | microphone | location | location-always | contacts | notifications | … On Android also camera, phone, sms, screen-capture (the MediaProjection app op) and all.',
            ),
            'bundleId': Schema.string(
              description:
                  'privacy: target app bundle id or Android package (grant/revoke). Default on Android: the attached app.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'status';
    if (op == 'screenshot' && session.active != null && (args['udid'] == null || args['apps'] != null)) {
      if (argBool(args, 'latest') ?? false) return _latest(session, args);
      return attachedScreenshot(session, args, request);
    }

    final udid = _resolveUdid(session, args['udid'] as String?);
    if (udid == null) {
      return StructuredResponse.error(
        summary: 'no target simulator',
        errorKind: GlintErrorKind.invalidArgument,
        nextSteps: const [
          'pass udid, or attach to an iOS simulator first',
        ],
      );
    }

    if (isPhysicalIosUdid(udid) && op == 'status') {
      final status = await phoneStatus(udid);
      if (status == null) {
        return StructuredResponse.error(
          summary: 'the iPhone $udid did not answer devicectl',
          errorKind: GlintErrorKind.deviceNotConnected,
          nextSteps: const ['connect and unlock the iPhone, then retry'],
        );
      }
      return StructuredResponse(
        summary: '${status['name']} · ${status['model']} · ${status['os']} (${status['build']}) · '
            '${status['connection']}, tunnel ${status['tunnel']} · developer mode ${status['developerMode']}'
            '${status['developerImage'] == true ? '' : ' · developer image not mounted'}'
            '${status['passcodeRequired'] == true ? ' · locked, needs its passcode' : ''}',
        data: {'udid': udid, ...status},
      );
    }
    if (isPhysicalIosUdid(udid) && op == 'network') {
      return _phoneNetwork(session, udid, (args['value'] as String?) ?? 'list');
    }
    if (isPhysicalIosUdid(udid) && op == 'openurl') {
      final url = args['value'] as String?;
      if (url == null || url.isEmpty) return _bad('op=openurl requires value: <url/deeplink>');
      final err = await phoneOpenUrl(udid, url);
      return _result(err, 'opened $url on $udid');
    }
    if (isPhysicalIosUdid(udid)) {
      final ability = switch (op) {
        'status' => Ability.deviceStatus,
        'appearance' => Ability.deviceAppearance,
        'openurl' => Ability.deviceOpenUrl,
        'privacy' => Ability.devicePrivacy,
        'biometric' || 'enrol' || 'unenrol' || 'match' || 'nomatch' => Ability.deviceBiometric,
        _ => null,
      };
      if (ability != null) return StructuredResponse.notOnThisDevice(ability, iphoneAbilities.gaps[ability]!);
    }
    if (_isAndroid(session, udid)) return _android(session, udid, op, args);

    const sim = SimControl();
    switch (op) {
      case 'status':
        final status = await sim.status(udid);
        if (status == null) {
          return StructuredResponse.error(
            summary: 'no simulator with udid $udid',
            errorKind: GlintErrorKind.targetNotFound,
          );
        }
        final title = status.deviceType != null && status.deviceType != status.name
            ? '${status.name} (${status.deviceType})'
            : status.name;
        return StructuredResponse(
          summary: [
            title,
            'os:         ${status.osVersion ?? "?"}',
            'state:      ${status.state}',
            'appearance: ${status.appearance ?? "?"}',
            'textSize:   ${status.contentSize ?? "?"}',
            'biometrics: ${switch (status.biometricEnrolled) {
              true => "enrolled",
              false => "not enrolled",
              null => "?",
            }}',
          ].join('\n'),
          data: {'status': status.toJson()},
        );

      case 'appearance':
        final value = args['value'] as String?;
        if (value != 'light' && value != 'dark') {
          return _bad('op=appearance requires value: light | dark');
        }
        final err = await sim.setAppearance(udid, value!);
        return _result(err, '$udid appearance → $value');

      case 'openurl':
        final url = args['value'] as String?;
        if (url == null || url.isEmpty) {
          return _bad('op=openurl requires value: <url/deeplink>');
        }
        final err = await sim.openUrl(udid, url);
        return _result(err, 'opened $url on $udid');

      case 'screenshot':
        final inline = argBool(args, 'inline') ?? false;
        final path = '${Directory.systemTemp.path}/glint-shot-$udid-'
            '${DateTime.now().millisecondsSinceEpoch}.png';
        final shot = await sim.screenshot(udid, path);
        if (shot.error != null || shot.path == null) {
          return StructuredResponse.error(
            summary: shot.error ?? 'screenshot failed',
            errorKind: GlintErrorKind.backendToolError,
          );
        }
        final dims = shot.width != null && shot.height != null ? ' (${shot.width}x${shot.height} px)' : '';
        final sent = inline && shot.width != null && shot.height != null
            ? await prepareModelImage(shot.path!,
                width: shot.width!,
                height: shot.height!,
                maxSize: argInt(args, 'maxSize') ?? session.config.screenshotMaxSize,
                format: session.config.screenshotFormat,
                quality: session.config.screenshotQuality)
            : null;
        return StructuredResponse(
          summary: 'screenshot saved: ${shot.path}$dims',
          nextSteps: [
            if (!inline) 'read the image at ${shot.path} to see the screen',
          ],
          data: {
            'ok': true,
            'path': shot.path,
            if (shot.width != null) 'width': shot.width,
            if (shot.height != null) 'height': shot.height,
            if (sent != null)
              'coordinates':
                  'image is ${sent.width}x${sent.height}; tap x,y in screen pixels = image pixel × ${(shot.width! / sent.width).toStringAsFixed(3)}',
          },
          imagePaths: [
            if (sent != null) sent.path else if (inline) shot.path!,
          ],
        );

      case 'biometric':
        return _biometric(sim, udid, args);

      case 'privacy':
        final action = args['action'] as String?;
        final service = args['service'] as String?;
        final bundleId = args['bundleId'] as String?;
        if (!const {'grant', 'revoke', 'reset'}.contains(action)) {
          return _bad('op=privacy requires action: grant | revoke | reset');
        }
        if (service == null || service.isEmpty) {
          return _bad('op=privacy requires service (e.g. photos, microphone)');
        }
        if (action != 'reset' && (bundleId == null || bundleId.isEmpty)) {
          return _bad('op=privacy $action requires bundleId');
        }
        final err = await sim.privacy(udid, action!, service, bundleId: bundleId);
        return _result(
            err,
            'privacy $action $service'
            '${bundleId != null ? " for $bundleId" : ""} on $udid');

      default:
        return _bad('unknown op: $op '
            '(use status | appearance | openurl | screenshot | privacy)');
    }
  }

  /// An adb serial: the attached Android device, an emulator, a Wi-Fi `host:port`, or a USB serial (letters and digits, no dashes, unlike a UDID).
  bool _isAndroid(GlintSession session, String id) =>
      (session.isAttached && session.device is AndroidDevice && session.device.id == id) ||
      RegExp(r'^emulator-\d+$').hasMatch(id) ||
      RegExp(r'^[\w.-]+:\d+$').hasMatch(id) ||
      RegExp(r'^[A-Za-z0-9]{8,}$').hasMatch(id);

  Future<StructuredResponse> _android(GlintSession session, String serial, String op, Map<String, Object?> args) async {
    if (op != 'privacy') {
      return StructuredResponse.error(
        summary: 'device op:$op is iOS simulator only; on Android only op:privacy is here',
        errorKind: GlintErrorKind.unsupportedBackendAction,
        nextSteps: const [
          '`media op:event` rotates and sends sensor, call and SMS events to an emulator',
          '`hardware_button` and `key` work on Android'
        ],
      );
    }
    final action = args['action'] as String?;
    final service = args['service'] as String?;
    if (!const {'grant', 'revoke', 'reset'}.contains(action)) {
      return _bad('op=privacy requires action: grant | revoke | reset');
    }
    if (service == null || service.isEmpty) {
      return _bad('op=privacy requires service (e.g. notifications, microphone, location, screen-capture)');
    }
    final attached = session.isAttached && session.device.id == serial ? session.device : null;
    final appId = (args['bundleId'] as String?) ?? (attached != null ? session.attachedBundleId : null);
    if (appId == null || appId.isEmpty) {
      return _bad('op=privacy needs bundleId: the Android package (or attach the app)');
    }
    final device = MediaDevice(DevicePlatform.android, serial,
        adbPath: attached is AndroidDevice ? attached.adbPath : (resolveAdbPath(null) ?? 'adb'));
    try {
      final done = await setAndroidPrivacy(device, appId, action!, service);
      return StructuredResponse(
        summary: '$appId on $serial · ${done.state}',
        warnings: [if (done.caution != null) done.caution!],
        nextSteps: const ['get_scene to see how the app reacts'],
        data: {'device': serial, 'appId': appId, 'service': service, 'action': action, 'applied': done.applied},
      );
    } on PermissionUnsupported catch (e) {
      return StructuredResponse.error(
          summary: e.reason, errorKind: GlintErrorKind.unsupportedBackendAction, nextSteps: e.nextSteps);
    } on PermissionRefused catch (e) {
      return StructuredResponse.error(
        summary: e.unknownApp
            ? '$appId is not installed on $serial'
            : e.notDeclared
                ? '$appId does not declare the permission for $service'
                : 'the device refused the change',
        errorKind: e.notDeclared || e.unknownApp ? GlintErrorKind.invalidArgument : GlintErrorKind.backendToolError,
        detail: e.detail,
        nextSteps: [
          if (e.notDeclared)
            'the app must declare the permission in its AndroidManifest.xml; Android ignores grants for undeclared ones',
          if (e.unknownApp) 'pass bundleId:"<the installed package>"',
        ],
      );
    }
  }

  /// The newest background capture (taken when the app left the foreground), or a new one when there is none.
  Future<StructuredResponse> _latest(GlintSession session, Map<String, Object?> args) async {
    final app = session.active!;
    final capture = app.captures.newest ?? await app.captureNow('explicit');
    if (capture == null) {
      return StructuredResponse.error(summary: 'screenshot failed', errorKind: GlintErrorKind.backendToolError);
    }
    final inline = argBool(args, 'inline') ?? false;
    final sent = inline ? await session.modelImage(capture.path, maxSize: argInt(args, 'maxSize')) : null;
    return StructuredResponse(
      summary: 'screenshot (newest capture): ${capture.path} (${capture.describe()})',
      nextSteps: [if (!inline) 'read the image at ${capture.path} to see the screen'],
      data: {
        'ok': true,
        ...capture.toJson(),
        'captures': app.captures.length,
        if (sent != null) 'coordinates': sent.coordinates,
        if (sent != null)
          'sent': {'width': sent.image.width, 'height': sent.image.height, 'mimeType': sent.image.mimeType},
      },
      imagePaths: [if (sent != null) sent.image.path],
    );
  }

  String? _resolveUdid(GlintSession session, String? arg) {
    if (arg != null && arg.isNotEmpty) return arg;
    return session.isAttached ? session.device.id : null;
  }

  StructuredResponse _result(String? err, String okSummary) {
    if (err != null) {
      return StructuredResponse.error(
        summary: err,
        errorKind: GlintErrorKind.backendToolError,
      );
    }
    return StructuredResponse(summary: okSummary, data: {'ok': true});
  }

  StructuredResponse _bad(String msg) => StructuredResponse.error(
        summary: msg,
        errorKind: GlintErrorKind.invalidArgument,
      );

  Future<StructuredResponse> _biometric(SimControl sim, String udid, Map<String, Object?> args) async {
    final action = args['action'] as String?;
    final type = (args['type'] as String?) ?? 'face';
    if (type != 'face' && type != 'touch') {
      return _bad('op=biometric type must be face or touch');
    }
    final label = type == 'face' ? 'Face ID' : 'Touch ID';
    switch (action) {
      case 'enrol' || 'unenrol':
        final enrol = action == 'enrol';
        final err = await sim.setBiometricEnrolled(udid, enrol);
        if (err != null) return _result(err, '');
        return StructuredResponse(
          summary: '$udid biometrics ${enrol ? "enrolled" : "unenrolled"}',
          data: {'ok': true, 'biometricEnrolled': enrol},
          nextSteps: [
            if (enrol) 'trigger the app\'s $label prompt, then device op:biometric action:match (or nomatch)',
          ],
        );
      case 'match' || 'nomatch':
        final enrolled = await sim.biometricEnrolled(udid);
        final err = await sim.biometricAttempt(udid, match: action == 'match', touch: type == 'touch');
        if (err != null) return _result(err, '');
        return StructuredResponse(
          summary: 'sent a ${action == 'match' ? "matching" : "non-matching"} '
              '${type == 'face' ? "face" : "finger"} to $udid',
          warnings: [
            if (enrolled == false)
              'biometrics are not enrolled, so no $label prompt can succeed; '
                  'device op:biometric action:enrol first',
          ],
          nextSteps: const [
            'read the screen: the prompt only reacts if it was showing when this was sent',
          ],
          data: {'ok': true, if (enrolled != null) 'enrolled': enrolled},
        );
      default:
        return _bad('op=biometric requires action: enrol | unenrol | match | nomatch');
    }
  }

  /// Lists, sets or clears a network condition on a phone through the Device Hub helper; it stays on until `off`, detach, or glint exits.
  Future<StructuredResponse> _phoneNetwork(GlintSession session, String udid, String value) async {
    final hid = session.isAttached && session.device.id == udid ? phoneHid(session.backend) : null;
    if (hid == null) {
      return StructuredResponse.error(
        summary: 'network conditions need the iPhone attached',
        errorKind: GlintErrorKind.sessionNotAttached,
        nextSteps: ['attach device:"$udid" (device mode works), then retry'],
      );
    }
    try {
      switch (value) {
        case 'list':
          final r = await hid.call(const {'cmd': 'networkList'});
          final conditions = (r['conditions'] as List? ?? const []).cast<Map>();
          return StructuredResponse(
            summary: '${conditions.length} network conditions: ${conditions.map((c) => c['profile']).join(', ')}',
            nextSteps: const ['device op:network value:"<profile>" turns one on; value:"off" clears it'],
            data: {
              'conditions': [
                for (final c in conditions)
                  {
                    'profile': c['profile'],
                    'group': c['group'],
                    'description': '${c['description']}'.split('\n').first.replaceFirst('Name: ', '')
                  }
              ]
            },
          );
        case 'off':
          await hid.call(const {'cmd': 'networkOff'});
          return StructuredResponse(summary: 'network condition cleared on $udid', data: const {'network': 'off'});
        default:
          final r = await hid.call({'cmd': 'networkOn', 'profile': value});
          final name = '${r['description']}'.split('\n').first.replaceFirst('Name: ', '');
          return StructuredResponse(
            summary: 'network condition $value on $udid: $name',
            warnings: const [
              'it affects every app on the phone until device op:network value:"off", detach, or glint exits'
            ],
            data: {'network': value, 'description': name},
          );
      }
    } on DeviceHidError catch (e) {
      return StructuredResponse.error(
        summary: 'network condition $value failed on $udid',
        errorKind: e.failure == DeviceHidFailure.badRequest ? GlintErrorKind.invalidArgument : e.failure.errorKind,
        detail: e.detail,
        nextSteps: value == 'list' ? e.nextSteps : const ['device op:network value:"list" shows the profiles'],
      );
    }
  }
}
