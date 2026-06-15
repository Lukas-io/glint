---
tool: type
description: Focus a typeable target and emit text.
when_to_use: Filling a `TextField`, `TextFormField`, `CupertinoTextField`, or any widget with the `>` marker in `get_scene`.
---

## DO NOT USE THIS TOOL WHEN

- The target has no `>` marker — it's not typeable. (A `*` marker on a `Container` that *looks* like an input doesn't make it typeable; the framework decides.)
- The text contains the literal newline-as-submit you want — pass `submit: true` instead of embedding `\n`.
- You want to clear a field — use `clear: true` (don't try to type a backspace burst).
- The keyboard is dismissed and the target isn't focused — the tool focuses it for you; you don't need to `tap` first.

## Use this when

- The user described what to type and which field to type it in.
- You're filling a form across several fields — one `type` per field, no need to dismiss the keyboard between.

## How it works

1. Resolves the target via the inspector.
2. If not currently focused, dispatches a focus request.
3. Clears the existing content if `clear: true`.
4. Emits the text via the platform backend (iOS Simulator: `HID` text input; Android: `adb shell input text`).
5. If `submit: true`, fires the on-keyboard "go" / "done" / "send" affordance.

## Args

- `glintId` (string, required).
- `text` (string, required) — what to type.
- `clear` (bool, optional, default false) — clear the field first.
- `submit` (bool, optional, default false) — fire the submit affordance after typing.
- `awaitReady` (bool, optional, default false) — armed intent.
- `readyTimeoutMs` (int, optional, default 5000).

## Returns

```json
{
  "summary": "typed 'wisdom@example.com' into email_field",
  "data": {
    "glintId": "email_field",
    "chars": 19,
    "cleared": true,
    "submitted": false
  }
}
```

Error (`unresolvedTarget`), (`notHittable`), (`targetNeverReady`) — same recovery as `tap`.

## Pairs well with

- `get_scene` after — to confirm the field's `textPreview` updated.
- `hardware_button name:"home"` — when you want to dismiss the keyboard and leave the screen.
