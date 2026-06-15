---
tool: wait_for_settle
description: Block until frames quiet AND no loading affordances remain visible. Use after async-triggering actions.
when_to_use: After an action that triggers a network call, navigation, or animation, before the next `get_scene` read.
---

## DO NOT USE THIS TOOL WHEN

- Your last action was synchronous (e.g. `type` into a `TextField` with no `onChanged` side effect) — no settle needed.
- You're tempted to wrap every action with it — the targeted action tools already accept `awaitReady: true` for chained-screen-transition arming, which is cheaper.
- You already see the screen you want in `get_scene` — there's nothing to wait for.
- An overlay is intentionally persistent (a modal sheet, a snackbar) — `wait_for_settle` will time out and report it.

## Use this when

- You just `tap`ped a button that triggers navigation; before reading the next screen.
- A pull-to-refresh is in progress.
- The previous response's `warnings` mentioned an in-flight animation.

## How it works

1. Polls `WidgetsBinding.instance.schedulerPhase` until it's `idle` (no frames pending).
2. Polls the scene for known loading affordances (`CircularProgressIndicator`, `LinearProgressIndicator`) and absorbers (`ModalBarrier` over a stale screen).
3. Both must agree the screen is stable for at least `quietWindowMs` before returning.

## Args

- `timeoutMs` (int, optional, default 5000) — give-up ceiling.
- `quietWindowMs` (int, optional, default 250) — how long things must stay calm to count.

## Returns

Success:
```json
{
  "summary": "settled in 1180ms (waited through ProgressIndicator)",
  "data": {
    "settled": true,
    "elapsedMs": 1180,
    "blockers": ["CircularProgressIndicator"]
  }
}
```

Timeout (still progress):
```json
{
  "isError": true,
  "data": {
    "errorKind": "internal",
    "blockers": ["LinearProgressIndicator"],
    "elapsedMs": 5000
  },
  "nextSteps": [
    "raise `timeoutMs`",
    "if the affordance is permanent (skeleton screen), proceed and read the scene anyway"
  ]
}
```

## Pairs well with

- Any action that triggers async work.
- `awaitReady: true` on the *next* targeted action — collapses settle + action into one server-side wait.
