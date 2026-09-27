import 'package:dart_mcp/server.dart';

import '../../../perception.dart';
import '../envelope.dart';
import '../session.dart';
import '../tool.dart';
import '../tool_args.dart';

/// §8.4: poll frame quiescence + loading affordances, return when the
/// screen is stable or the ceiling is reached.
class WaitForSettleTool extends GlintTool {
  const WaitForSettleTool();

  @override
  Tool get definition => Tool(
        name: 'wait_for_settle',
        description:
            'Wait until the screen is stable: no scheduled frames and no loading spinners. For async work you started (network, animation, route change); actions already settle themselves. ceilingMs default 5000. settled:false means it was still loading at the ceiling: check what is loading, then wait again or raise ceilingMs. Device mode: flutterModeRequired.',
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
    final ceilingMs =
        argInt(args, 'ceilingMs') ?? session.config.settleCeilingMs;
    final quietFrames =
        argInt(args, 'quietFrames') ?? session.config.settleQuietFrames;
    final checkAffordances = argBool(args, 'checkLoadingAffordances') ?? true;

    final result = await session.settleDetector.awaitSettle(
      ceilingMs: ceilingMs,
      quietFramesNeeded: quietFrames,
      checkLoadingAffordances: checkAffordances,
    );

    switch (result) {
      case SettledOk():
        return StructuredResponse(
          summary: checkAffordances
              ? 'settled in ${result.elapsedMs}ms (frames quiet, no spinner)'
              : 'settled in ${result.elapsedMs}ms (frames quiet)',
          data: {'settled': true, 'elapsedMs': result.elapsedMs},
        );
      case SettledAnimating():
        return StructuredResponse(
          summary: 'settled in ${result.elapsedMs}ms (frames still animating, '
              'content stable)',
          data: {
            'settled': true,
            'elapsedMs': result.elapsedMs,
            'animating': true,
          },
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
