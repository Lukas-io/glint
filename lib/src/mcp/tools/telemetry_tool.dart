import 'package:dart_mcp/server.dart';

import '../../../interaction.dart';
import '../../../observability.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// Inspect or trigger glint's telemetry pipeline:
///   status — opt-out + recorder + store + watermark state
///   report — local rollup: per-tool stats, error kinds, transitions
///   ship   — build + send a rollup now (also writes audit log)
///   dryRun — like ship but doesn't post or advance the watermark
///   token_usage  — estimated agent-side token cost per tool
///   audit_show   — pretty-print recent audit entries
///   audit_verify — walk the hash chain
/// Telemetry is ON by default; set GLINT_NO_TELEMETRY=true to disable.
class TelemetryTool extends GlintTool {
  const TelemetryTool();

  @override
  Tool get definition => Tool(
        name: 'telemetry',
        description:
            'Glint telemetry control + transparency. ops: status (default), '
            'report, ship, dryRun, token_usage, audit_show, audit_verify. '
            'report = local usage rollup (per-tool counts, error kinds, latency, '
            'transitions) with nothing sent anywhere. Telemetry is ON by '
            'default; opt out via env: GLINT_NO_TELEMETRY=true (everything) or '
            'GLINT_NO_USAGE=true (usage only).',
        inputSchema: ObjectSchema(
          properties: {
            'op': Schema.string(
              description:
                  'status (default) | report | ship | dryRun | token_usage | '
                  'audit_show | audit_verify',
            ),
            'limit': Schema.int(
              description:
                  'For audit_show / token_usage / report: max entries to '
                  'return (default 20 / 10 / 15).',
            ),
            'sinceId': Schema.int(
              description:
                  'For token_usage / report: only count events with id > '
                  'sinceId (default 0 = everything recorded).',
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
        return _status(session, dataDir);
      case 'report':
        return _report(session, args);
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
        final result =
            await session.usageReporter.ship(dataDir: dataDir, dryRun: true);
        return StructuredResponse(
          summary: result.message,
          data: {
            'dryRun': true,
            'events': result.events,
            if (result.payloadJson != null) 'payload': result.payloadJson,
          },
        );
      case 'token_usage':
        return _tokenUsage(session, args);
      case 'audit_show':
        return _auditShow(dataDir, args);
      case 'audit_verify':
        return _auditVerify(dataDir);
      default:
        return StructuredResponse.error(
          summary: 'unknown op: $op',
          errorKind: GlintErrorKind.invalidArgument,
          nextSteps: const [
            'use one of: status, report, ship, dryRun, token_usage, '
                'audit_show, audit_verify'
          ],
        );
    }
  }

  StructuredResponse _status(GlintSession session, String dataDir) {
    final disabled = telemetryDisabled();
    final usageOff = usageDisabled();
    final store = session.usage.store;
    final unshipped =
        usageOff ? 0 : session.usageReporter.unshippedCount(dataDir: dataDir);
    return StructuredResponse(
      summary: [
        'telemetry: ${disabled ? "DISABLED (GLINT_NO_TELEMETRY)" : "enabled"}',
        'usage:     ${usageOff ? "DISABLED" : "enabled"}',
        'this run:  ${session.usage.length} event(s); nextId=${session.usage.nextId}',
        'store:     ${store == null ? "(memory only)" : "${store.path} (${store.count()} persisted)"}',
        'unshipped: $unshipped event(s) — ships daily at startup and on exit',
        'collector: $kCollectorEndpoint',
      ].join('\n'),
      data: {
        'telemetryDisabled': disabled,
        'usageDisabled': usageOff,
        'recorderEvents': session.usage.length,
        'recorderNextId': session.usage.nextId,
        'persisted': store?.count() ?? 0,
        'unshipped': unshipped,
        'storePath': store?.path,
        'dataDir': dataDir,
        'collectorEndpoint': kCollectorEndpoint,
      },
    );
  }

  StructuredResponse _report(GlintSession session, Map<String, Object?> args) {
    final sinceId = (args['sinceId'] as int?) ?? 0;
    final limit = (args['limit'] as int?) ?? 15;
    final rows = session.usage.eventsAfterId(sinceId);
    if (rows.isEmpty) {
      return StructuredResponse(
        summary: 'no tool calls recorded${sinceId > 0 ? " after id=$sinceId" : ""}',
        data: {'totalEvents': 0, 'sinceId': sinceId},
      );
    }
    final stats = summarizeUsage(rows, topTransitions: limit);
    final tools = (stats['tools'] as List).cast<Map<String, Object?>>();
    final transitions =
        (stats['transitions'] as List).cast<Map<String, Object?>>();
    final selfCorr = (stats['selfCorrection'] as List?)
            ?.cast<Map<String, Object?>>() ??
        const [];
    final lines = <String>[
      '${stats['totalEvents']} call(s) over ${stats['totalTurns']} turn(s)'
          '${stats['totalEstimatedTokens'] != null ? ", ~${stats['totalEstimatedTokens']} tokens returned" : ""}',
      'tools:',
      for (final t in tools.take(limit))
        '  ${(t['tool'] as String).padRight(16)} '
            '${(t['count'] as int).toString().padLeft(4)}x  '
            'err ${(((t['errorRate'] as num) * 100).round()).toString().padLeft(3)}%  '
            'p50 ${t['p50Ms'] ?? "-"}ms  p95 ${t['p95Ms'] ?? "-"}ms'
            '${t['errorKinds'] != null ? "  kinds ${_kinds(t['errorKinds'] as Map)}" : ""}',
      if (transitions.isNotEmpty) 'top transitions:',
      for (final tr in transitions.take(limit))
        '  ${tr['count'].toString().padLeft(4)}  ${tr['from']}[${tr['fromOutcome']}] → ${tr['to']}',
      if (selfCorr.isNotEmpty) 'after an error, next call succeeded:',
      for (final sc in selfCorr.take(limit))
        '  ${sc['tool']}[${sc['signal']}]  ${sc['recovered']}/${sc['occurrences']}',
    ];
    return StructuredResponse(
      summary: lines.join('\n'),
      data: {'sinceId': sinceId, ...stats},
    );
  }

  String _kinds(Map kinds) => kinds.entries
      .map((e) => '${e.key}×${e.value}')
      .join(' ');

  StructuredResponse _tokenUsage(GlintSession session, Map<String, Object?> args) {
    final sinceId = (args['sinceId'] as int?) ?? 0;
    final topN = (args['limit'] as int?) ?? 10;
    final rows = session.usage.eventsAfterId(sinceId);
    if (rows.isEmpty) {
      return StructuredResponse(
        summary: session.usage.length == 0
            ? 'no tool calls recorded yet'
            : 'no events newer than id=$sinceId '
                '(recorder holds ${session.usage.length})',
        data: {
          'totalEvents': 0,
          'totalEstimatedTokens': 0,
          'sinceId': sinceId,
          'charsPerToken': kCharsPerToken,
          'recorderEvents': session.usage.length,
          'recorderNextId': session.usage.nextId,
        },
      );
    }

    final perTool = <String, _TokenAgg>{};
    var totalTokens = 0;
    final largest = <Map<String, Object?>>[];
    for (final r in rows) {
      final tool = (r['tool'] as String?) ?? '?';
      final bytes = (r['result_bytes'] as int?) ?? 0;
      final tokens = estimateTokens(bytes);
      totalTokens += tokens;
      perTool
          .putIfAbsent(tool, () => _TokenAgg(tool))
          .add(tokens: tokens, bytes: bytes);
      largest.add({
        'id': r['id'],
        'tool': tool,
        'durationMs': r['duration_ms'],
        'tokens': tokens,
        'bytes': bytes,
      });
    }
    largest.sort(
      (a, b) => (b['tokens'] as int).compareTo(a['tokens'] as int),
    );
    final topList = largest.take(topN).toList();

    final perToolList = perTool.values.map((a) => a.toJson()).toList()
      ..sort(
        (a, b) =>
            (b['totalTokens'] as int).compareTo(a['totalTokens'] as int),
      );

    final topToolLines = perToolList.take(5).map((t) =>
        '  ${(t['tool'] as String).padRight(18)} '
        '${(t['count'] as int).toString().padLeft(4)}x  '
        '${(t['totalTokens'] as int).toString().padLeft(7)} tok  '
        '(avg ${t['avgTokens']}, max ${t['maxTokens']})');

    return StructuredResponse(
      summary: [
        '~$totalTokens tokens across ${rows.length} call(s) '
            '(est. resultBytes/${kCharsPerToken.toInt()})',
        'top tools:',
        ...topToolLines,
      ].join('\n'),
      data: {
        'totalEvents': rows.length,
        'totalEstimatedTokens': totalTokens,
        'sinceId': sinceId,
        'charsPerToken': kCharsPerToken,
        'estimationNote':
            'tokens estimated as resultBytes / $kCharsPerToken; '
                'real model tokenization will differ.',
        'perTool': perToolList,
        'topResponses': topList,
        'recorderEvents': session.usage.length,
        'recorderNextId': session.usage.nextId,
      },
    );
  }

  StructuredResponse _auditShow(String dataDir, Map<String, Object?> args) {
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
        'entries': [
          for (final e in tail)
            {
              'ts': e.ts.toIso8601String(),
              'thisHash': e.thisHash,
              'prevHash': e.prevHash,
              'payload': e.decodePayload(),
            }
        ],
      },
    );
  }

  StructuredResponse _auditVerify(String dataDir) {
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
        if (result.brokenAtIndex != null) 'brokenAtIndex': result.brokenAtIndex,
        if (result.brokenReason != null) 'brokenReason': result.brokenReason,
        if (result.firstTs != null) 'firstTs': result.firstTs!.toIso8601String(),
        if (result.lastTs != null) 'lastTs': result.lastTs!.toIso8601String(),
      },
    );
  }
}

class _TokenAgg {
  _TokenAgg(this.tool);

  final String tool;
  int count = 0;
  int totalTokens = 0;
  int totalBytes = 0;
  int maxTokens = 0;

  void add({required int tokens, required int bytes}) {
    count++;
    totalTokens += tokens;
    totalBytes += bytes;
    if (tokens > maxTokens) maxTokens = tokens;
  }

  Map<String, Object?> toJson() => {
        'tool': tool,
        'count': count,
        'totalTokens': totalTokens,
        'avgTokens': count == 0 ? 0 : (totalTokens / count).round(),
        'maxTokens': maxTokens,
        'totalBytes': totalBytes,
      };
}
