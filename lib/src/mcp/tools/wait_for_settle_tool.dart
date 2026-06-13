import 'package:dart_mcp/server.dart';

import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';

/// §8.4: poll frame quiescence + loading affordances, return when the
/// screen is stable or the ceiling is reached.
class WaitForSettleTool extends GlintTool {
  const WaitForSettleTool();

  @override
  Tool get definition => Tool(
        name: 'wait_for_settle',
        description: 'Block until the screen settles (no scheduled frames, '
            'no loading affordances) or `ceilingMs` is reached.',
        inputSchema: ObjectSchema(
          properties: {
            'ceilingMs': Schema.int(
              description: 'Hard cap on wait time. Default 5000.',
            ),
            'quietFrames': Schema.int(
              description:
                  'Consecutive quiet polls required to declare settled. Default 3.',
            ),
            'checkLoadingAffordances': Schema.bool(
              description:
                  'When true, frame-quiet still polls if any CircularProgressIndicator / '
                  'LinearProgressIndicator / RefreshIndicator is in the scene. Default true.',
            ),
          },
        ),
      );

  @override
  Future<StructuredResponse> handle(
      GlintSession session, CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final ceilingMs = (args['ceilingMs'] as int?) ?? 5000;
    final quietFrames = (args['quietFrames'] as int?) ?? 3;
    final checkAffordances = (args['checkLoadingAffordances'] as bool?) ?? true;

    final result = await session.settleDetector.awaitSettle(
      ceilingMs: ceilingMs,
      quietFramesNeeded: quietFrames,
      checkLoadingAffordances: checkAffordances,
    );

    switch (result) {
      case SettledOk():
        return StructuredResponse(
          summary: 'settled in ${result.elapsedMs}ms',
          data: {'settled': true, 'elapsedMs': result.elapsedMs},
        );
      case SettledButLoading():
        return StructuredResponse(
          summary: 'frame-quiet but loading affordances still present after '
              '${result.elapsedMs}ms',
          warnings: [
            for (final id in result.loadingAffordances) 'loading: $id',
          ],
          data: {
            'settled': false,
            'elapsedMs': result.elapsedMs,
            'loadingAffordances': result.loadingAffordances,
          },
        );
      case SettleTimedOut():
        return StructuredResponse(
          summary: 'ceiling reached after ${result.elapsedMs}ms; screen still active',
          data: {'settled': false, 'elapsedMs': result.elapsedMs},
          warnings: const ['frame pipeline never went quiet'],
        );
    }
  }
}
