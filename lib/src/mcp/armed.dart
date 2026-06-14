import '../../interaction.dart';
import '../../perception.dart';
import 'envelope.dart';
import 'session.dart';

/// Shared armed-intent gate for targeted action tools.
/// Returns one of three outcomes; callers branch sealed-style.
sealed class ArmingOutcome {
  const ArmingOutcome();
}

class ArmingSkipped extends ArmingOutcome {
  const ArmingSkipped();
}

class ArmingReady extends ArmingOutcome {
  const ArmingReady({required this.attempts, required this.elapsedMs});
  final int attempts;
  final int elapsedMs;

  Map<String, Object?> toJson() => {
        'attempts': attempts,
        'elapsedMs': elapsedMs,
      };
}

class ArmingFailed extends ArmingOutcome {
  const ArmingFailed(this.envelope);
  final StructuredResponse envelope;
}

/// If [awaitReady] is true, polls until [glintId] is hittable. Returns
/// `ArmingReady` on success (caller proceeds with the action and tags
/// armed metadata onto the response), `ArmingFailed` with a ready-to-
/// return envelope on miss, or `ArmingSkipped` when [awaitReady] is false.
Future<ArmingOutcome> maybeAwaitReady({
  required GlintSession session,
  required String glintId,
  required bool awaitReady,
  required int ceilingMs,
  String? toolLabel,
}) async {
  if (!awaitReady) return const ArmingSkipped();
  final result = await session.readinessGate
      .awaitReady(glintId: glintId, ceilingMs: ceilingMs);
  switch (result) {
    case ReadyResult():
      return ArmingReady(
          attempts: result.attempts, elapsedMs: result.elapsedMs);
    case NotFoundResult():
      return ArmingFailed(StructuredResponse.error(
        summary: '${toolLabel ?? "action"} on $glintId: target never appeared '
            '(${result.attempts} polls, ${result.elapsedMs}ms)',
        errorKind: GlintErrorKind.unresolvedTarget,
        detail: 'no scene poll within $ceilingMs ms saw glintId="$glintId"',
        nextSteps: const [
          'verify the glintId via `get_scene`',
          'raise `readyTimeoutMs` if the target arrives slowly',
        ],
      ));
    case NeverReadyResult():
      return ArmingFailed(StructuredResponse.error(
        summary: '${toolLabel ?? "action"} on $glintId: present but never '
            'hittable (${result.attempts} polls, ${result.elapsedMs}ms)',
        errorKind: GlintErrorKind.targetNeverReady,
        detail: result.detail,
        nextSteps: const [
          'check if a modal, absorber, or overlay covers the target',
          'raise `readyTimeoutMs` if the target settles slowly',
        ],
      ));
  }
}

/// Wraps an action's [StructuredResponse] with armed metadata. Use after
/// the action fires when [arming] reports ready.
StructuredResponse withArmedMetadata(
    StructuredResponse response, ArmingReady arming) {
  return StructuredResponse(
    summary:
        'armed (${arming.attempts} polls / ${arming.elapsedMs}ms) — ${response.summary}',
    warnings: response.warnings,
    nextSteps: response.nextSteps,
    data: {...?response.data, 'armed': arming.toJson()},
    isError: response.isError,
  );
}
