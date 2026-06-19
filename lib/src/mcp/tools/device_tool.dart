import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// `device` — inspect or configure an iOS simulator. Defaults to the device
/// glint is attached to; pass `udid` to target another booted sim.
///
/// ops: status (default) | appearance | openurl | privacy. Heavier control
/// (location, biometrics, push, status-bar) is roadmapped.
class DeviceTool extends GlintTool {
  const DeviceTool();

  @override
  Tool get definition => Tool(
        name: 'device',
        description:
            'Inspect or configure an iOS simulator. Defaults to the attached '
            'device; pass udid to target another booted sim. '
            'op: status (default) returns name, OS, device type, state, '
            'appearance (light/dark), content size. '
            'appearance — set value: light|dark. '
            'openurl — open value: <url/deeplink>. '
            'privacy — action: grant|revoke|reset, service: '
            'photos|camera|location|contacts|…, bundleId for grant/revoke. '
            'errorKind: invalidArgument (bad op/args, no udid), '
            'targetNotFound (no such sim), backendToolError (simctl failed).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description: 'status (default) | appearance | openurl | privacy',
            ),
            'udid': Schema.string(
              description:
                  'Target simulator UDID. Defaults to the attached device.',
            ),
            'value': Schema.string(
              description: 'appearance: light|dark. openurl: the URL.',
            ),
            'action': Schema.string(
              description: 'privacy: grant | revoke | reset',
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
            '(use status | appearance | openurl | privacy)');
    }
  }

  String? _resolveUdid(GlintSession session, String? arg) {
    if (arg != null && arg.isNotEmpty) return arg;
    if (session.isAttached) {
      final device = session.device;
      if (device is IosSimulator) return device.udid;
    }
    return null;
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
}
