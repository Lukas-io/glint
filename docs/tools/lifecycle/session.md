---
tool: session
description: Inspect glint's current session state (attached app, focused widget, lifecycle, keyboard, orientation) or list past sessions.
when_to_use: Before re-attaching, when verifying app state, or to recover context after a long pause.
---

## DO NOT USE THIS TOOL WHEN

- You just want the widget tree — that's `get_scene`. `session` returns *meta* about the attachment, not the scene.
- You're trying to find a specific widget by id — that's also `get_scene`.
- You want raw VM state — glint deliberately doesn't expose that; if you really need it, file a `feature` request via `report_issue`.

## Use this when

- You're not sure whether glint is currently attached, and to which app.
- You need to know the focused widget's runtime type (`TextField` vs `EditableText`), the keyboard's bottom inset, the device orientation, brightness, or locale — `session` fetches all of them in one VM eval (~50ms).
- You want the current `AppLifecycleState` (`resumed` / `inactive` / `paused` / `hidden` / `detached`).
- You're about to drive a destructive action and want to confirm "yes, this is the right app".

## How it works

1. Reads attach metadata from the in-memory session (no VM call).
2. If attached, runs one VM eval that returns `focusedType|keyboardBottomPx|orientation|brightness|locale` in a single round-trip.
3. Runs a second eval for the lifecycle state.

## Args

- `op` (string, optional, default `status`) — currently only `status` is supported.

## Returns

When attached:
```json
{
  "summary": "attached to ios <UDID>; focus=TextField; lifecycle=resumed",
  "data": {
    "attached": true,
    "platform": "ios",
    "device": "<UDID>",
    "focusedType": "TextField",
    "keyboardBottomPx": 291.0,
    "orientation": "portrait",
    "brightness": "light",
    "locale": "en_US",
    "lifecycleState": "resumed"
  }
}
```

When detached:
```json
{
  "summary": "glint is not attached",
  "data": {"attached": false},
  "nextSteps": ["call `attach` with the running app's VM URI"]
}
```

## Pairs well with

- `attach` — when `attached:false`, this is the next call.
- `get_scene` — when you want to see what's on screen.
- `wait_for_settle` — when `lifecycleState != "resumed"` and you suspect the app is mid-transition.
