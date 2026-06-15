---
tool: resolve
description: Turn a glintId into logical + physical coordinates and viewport metadata, without taking an action.
when_to_use: When you need the geometry of a widget but don't want to fire an action — e.g. logging coordinates, validating a screenshot, debugging hit-test failures.
---

## DO NOT USE THIS TOOL WHEN

- You're about to tap / type / drag the same widget — the action tools resolve internally; calling `resolve` first is redundant work.
- You want to verify a widget *exists* — `get_scene` returns the id; `resolve` only adds coordinates.
- You're trying to bypass `notHittable` errors — `resolve` returns the geometry even when the widget is covered. Acting on that geometry will fail downstream. Dismiss the cover instead.

## Use this when

- You're filing a `bug` against a coordinate-resolution failure and want the resolver's raw output for the report.
- You need the logical viewport size + DPR programmatically (returned in every response).
- You're cross-referencing a glint coordinate against a screenshot or a hit-test in your own code.

## How it works

1. Calls `ext.flutter.inspector.setSelectionById` to focus the framework's inspector on the target widget.
2. Evaluates a single VM expression returning `Rect.fromLTWH(...) | logicalViewSize.toString() | devicePixelRatio` in a pipe-delimited string. Handles inspector truncation via `getObject` refetch.
3. Returns logical and physical coordinates.

## Args

- `glintId` (string, required) — from the most recent `get_scene`.

## Returns

```json
{
  "summary": "sign_out_button at (172, 689) (logical), 84×40, viewport 390×844, dpr 3.0",
  "data": {
    "glintId": "sign_out_button",
    "logicalRect": {"left": 172.0, "top": 689.0, "width": 84.0, "height": 40.0},
    "physicalRect": {"left": 516.0, "top": 2067.0, "width": 252.0, "height": 120.0},
    "logicalViewSize": {"w": 390.0, "h": 844.0},
    "devicePixelRatio": 3.0
  }
}
```

Error (`unresolvedTarget`) — the id doesn't exist in the current tree. Call `get_scene` and pick a real id.
Error (`geometryResolveError`) — inspector eval failed. Retry; if it persists, file a `bug`.

## Pairs well with

- `get_scene` — the previous step. `resolve` doesn't list ids.
- The action tools — they wrap `resolve` internally; you don't usually need this directly.
