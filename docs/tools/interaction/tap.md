---
tool: tap
description: Single tap on a tappable target.
when_to_use: The default action. Use this for buttons, list tiles, icons, anything the user would tap with one finger.
---

## DO NOT USE THIS TOOL WHEN

- The target has no `*` marker in `get_scene` — it's not classified as tappable. Use `resolve` + coordinates only if you're sure (rare).
- You need to press-and-hold for a context menu — use `long_press`.
- The button is intentionally double-tap-only — use `double_tap`.
- The target is behind a `ModalBarrier` / overlay — `notHittable` will fire. Dismiss the cover first.
- You're trying to "scroll to it" by tapping below the fold — that's `scroll_to_find`.

## Use this when

- The widget is visible AND hittable AND has the `*` marker in `get_scene`.
- You want to chain across a screen transition — pass `awaitReady: true` (server polls until the target exists + passes a hit test, then fires). Default ceiling `readyTimeoutMs: 5000`.

## How it works

1. Resolves the glintId via the inspector to logical + physical coordinates.
2. If `awaitReady: true`, polls until the target exists and a hit test at its center returns the same widget.
3. Fires a single-point tap via the platform backend.

## Args

- `glintId` (string, required) — from `get_scene`.
- `awaitReady` (bool, optional, default false) — see above.
- `readyTimeoutMs` (int, optional, default 5000) — armed ceiling.

## Returns

Success:
```json
{
  "summary": "tapped sign_out_button",
  "data": {
    "glintId": "sign_out_button",
    "physical": {"x": 642, "y": 2127}
  }
}
```

Error (`unresolvedTarget`) — id not in current tree. `get_scene` and pick a real id.
Error (`notHittable`) — covered by an overlay. Dismiss; retry.
Error (`targetNeverReady`) — armed ceiling hit; target stayed unhittable. Raise the timeout or fix the cover.

## Pairs well with

- `get_scene` — before AND after.
- `awaitReady: true` — for screen-transition chains.
