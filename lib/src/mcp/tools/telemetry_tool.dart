import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Inspect or trigger glint's telemetry pipeline:
///   status — current opt-out + recorder + watermark state
///   ship   — build + send a rollup now (also writes audit log)
///   dryRun — like ship but doesn't post or advance the watermark
///   audit_show   — pretty-print recent audit entries
///   audit_verify — walk the hash chain
class TelemetryTool extends GlintTool {
  const TelemetryTool();

  @override
  Tool get definition => Tool(
        name: 'telemetry',
        description:
            'Glint telemetry control + transparency. ops: status (default), '
            'ship, dryRun, audit_show, audit_verify. Opt out via env: '
            'GLINT_NO_TELEMETRY=true (everything) or GLINT_NO_USAGE=true '
            '(usage only).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description:
                  'status (default) | ship | dryRun | audit_show | audit_verify',
            ),
            'limit': Schema.int(
              description:
                  'For audit_show: max entries to print (default 20).',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final op = (args['op'] as String?) ?? 'status';
    final dataDir = resolveDataDir();

    switch (op) {
      case 'status':
        final disabled = telemetryDisabled();
        final usageOff = usageDisabled();
        return StructuredResponse(
          summary: [
            'telemetry: ${disabled ? "DISABLED (GLINT_NO_TELEMETRY)" : "enabled"}',
            'usage:     ${usageOff ? "DISABLED" : "enabled"}',
            'recorder:  ${session.usage.length} event(s) since last ship; nextId=${session.usage.nextId}',
            'dataDir:   $dataDir',
            'collector: $kCollectorEndpoint',
          ].join('\n'),
          data: {
            'telemetryDisabled': disabled,
            'usageDisabled': usageOff,
            'recorderEvents': session.usage.length,
            'recorderNextId': session.usage.nextId,
            'dataDir': dataDir,
            'collectorEndpoint': kCollectorEndpoint,
          },
        );

      case 'ship':
        final result = await session.usageReporter.ship(dataDir: dataDir);
        return StructuredResponse(
          summary: result.message,
          data: {
            'shipped': result.shipped,
            'events': result.events,
            'posted': result.posted,
            'fromEventId': result.fromEventId,
            'toEventId': result.toEventId,
            if (result.payloadJson != null) 'payload': result.payloadJson,
          },
        );

      case 'dryRun':
        final result = await session.usageReporter
            .ship(dataDir: dataDir, dryRun: true);
        return StructuredResponse(
          summary: result.message,
          data: {
            'dryRun': true,
            'events': result.events,
            if (result.payloadJson != null) 'payload': result.payloadJson,
          },
        );

      case 'audit_show':
        final limit = (args['limit'] as int?) ?? 20;
        final entries = AuditLog.readAll(dataDir).whereType<AuditEntry>().toList();
        final tail = entries.length > limit
            ? entries.sublist(entries.length - limit)
            : entries;
        final lines = tail.map((e) =>
            '${e.ts.toIso8601String()} ${e.thisHash.substring(0, 12)} '
            '(${e.payloadB64.length}b payload)');
        return StructuredResponse(
          summary: tail.isEmpty
              ? '(no audit entries at $dataDir/telemetry-audit.log)'
              : lines.join('\n'),
          data: {
            'totalEntries': entries.length,
            'shown': tail.length,
            'entries': [for (final e in tail)
              {
                'ts': e.ts.toIso8601String(),
                'thisHash': e.thisHash,
                'prevHash': e.prevHash,
                'payload': e.decodePayload(),
              }],
          },
        );

      case 'audit_verify':
        final result = AuditLog.verify(dataDir);
        return StructuredResponse(
          summary: result.intact
              ? 'intact: ${result.totalEntries} entries '
                  '${result.firstTs?.toIso8601String() ?? ""}..'
                  '${result.lastTs?.toIso8601String() ?? ""}'
              : 'BROKEN at entry #${result.brokenAtIndex}: ${result.brokenReason}',
          isError: !result.intact,
          data: {
            'intact': result.intact,
            'totalEntries': result.totalEntries,
            if (result.brokenAtIndex != null)
              'brokenAtIndex': result.brokenAtIndex,
            if (result.brokenReason != null)
              'brokenReason': result.brokenReason,
            if (result.firstTs != null) 'firstTs': result.firstTs!.toIso8601String(),
            if (result.lastTs != null) 'lastTs': result.lastTs!.toIso8601String(),
          },
        );

      default:
        return StructuredResponse.error(
          summary: 'unknown op: $op',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const ['use one of: status, ship, dryRun, audit_show, audit_verify'],
        );
    }
  }
}
