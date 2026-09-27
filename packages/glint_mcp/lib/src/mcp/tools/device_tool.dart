import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
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
            'Inspect or configure an iOS simulator: the attached one, or udid. op: status (default), appearance, openurl, screenshot (PNG, works headless), privacy, biometric; each argument names the ops it serves. errorKind: invalidArgument, targetNotFound, backendToolError (simctl failed).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description:
                  'status (default) | appearance | openurl | screenshot | '
                  'privacy | biometric',
            ),
            'udid': Schema.string(
              description:
                  'Target simulator UDID. Defaults to the attached device.',
            ),
            'inline': Schema.bool(
              description: 'op=screenshot: also return the image as image '
                  'content, so no separate read is needed. Default false.',
            ),
            'maxSize': Schema.int(
              description: 'op=screenshot inline: longest side in pixels of the '
                  'image sent (0 = full size). Default: the screenshotMaxSize config (1024).',
            ),
            'latest': Schema.bool(
              description:
                  'screenshot only: return the newest background capture '
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
              description: 'privacy: photos | camera | location | contacts | …',
            ),
            'bundleId': Schema.string(
              description: 'privacy: target app bundle id (grant/revoke).',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'status';

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
        final title = status.deviceType != null &&
                status.deviceType != status.name
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
        final app = session.active;
        if (app != null && (args['udid'] as String?) == null) {
          final latest = argBool(args, 'latest') ?? false;
          final capture = latest
              ? (app.captures.newest ?? await app.captureNow('explicit'))
              : await app.captureNow('explicit');
          if (capture == null) {
            return StructuredResponse.error(
              summary: 'screenshot failed',
              errorKind: GlintErrorKind.backendToolError,
            );
          }
          final sent = inline
              ? await session.modelImage(capture.path, maxSize: argInt(args, 'maxSize'))
              : null;
          return StructuredResponse(
            summary: 'screenshot ${latest ? "(newest capture)" : "saved"}: '
                '${capture.path} (${capture.describe()})',
            nextSteps: [
              if (!inline) 'read the image at ${capture.path} to see the screen',
            ],
            data: {
              'ok': true,
              ...capture.toJson(),
              'captures': app.captures.length,
              if (sent != null) 'coordinates': sent.coordinates,
              if (sent != null) 'sent': {'width': sent.image.width, 'height': sent.image.height, 'mimeType': sent.image.mimeType},
            },
            imagePaths: [if (sent != null) sent.image.path],
          );
        }
        final path = '${Directory.systemTemp.path}/glint-shot-$udid-'
            '${DateTime.now().millisecondsSinceEpoch}.png';
        final shot = await sim.screenshot(udid, path);
        if (shot.error != null || shot.path == null) {
          return StructuredResponse.error(
            summary: shot.error ?? 'screenshot failed',
            errorKind: GlintErrorKind.backendToolError,
          );
        }
        final dims = shot.width != null && shot.height != null
            ? ' (${shot.width}x${shot.height} px)'
            : '';
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
              'coordinates': 'image is ${sent.width}x${sent.height}; tap x,y in screen pixels = image pixel × ${(shot.width! / sent.width).toStringAsFixed(3)}',
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
          return _bad('op=privacy requires service (e.g. photos, camera)');
        }
        if (action != 'reset' && (bundleId == null || bundleId.isEmpty)) {
          return _bad('op=privacy $action requires bundleId');
        }
        final err = await sim.privacy(udid, action!, service, bundleId: bundleId);
        return _result(err, 'privacy $action $service'
            '${bundleId != null ? " for $bundleId" : ""} on $udid');

      default:
        return _bad('unknown op: $op '
            '(use status | appearance | openurl | screenshot | privacy)');
    }
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

  Future<StructuredResponse> _biometric(
      SimControl sim, String udid, Map<String, Object?> args) async {
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
            if (enrol)
              'trigger the app\'s $label prompt, then device op:biometric action:match (or nomatch)',
          ],
        );
      case 'match' || 'nomatch':
        final enrolled = await sim.biometricEnrolled(udid);
        final err = await sim.biometricAttempt(udid,
            match: action == 'match', touch: type == 'touch');
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
}
