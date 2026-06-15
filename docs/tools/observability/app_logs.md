---
tool: app_logs
description: The running Flutter app's stderr / stdout / `developer.log` output, captured continuously from the VM service.
when_to_use: Debugging a crash inside the app, surfacing a FlutterError, finding what the app printed in response to your action.
---

## DO NOT USE THIS TOOL WHEN

- You want glint's action log — that's `logs`. `app_logs` is the *app's* output.
- The app is in release / profile mode — VM streams are stripped.
- You want crash reports about glint itself — those live in glint's `telemetry op:"audit_show"`.

## Use this when

- You just performed an action and want to see what the app printed in response.
- You're investigating a `FlutterError` — they route through `debugPrint` → stdout, not stderr; this tool merges both.
- You're filing a `bug` via `report_issue` and need to attach the error context (the tool auto-attaches the most recent errors).

## How it works

Bounded ring (default 500 entries) backed by VM service stream subscriptions. The app log buffer starts capturing the moment `attach` succeeds and continues across re-attach. Each entry has: sequence id, timestamp, stream (`stderr` / `stdout` / `logging`), content, optional logger name + level.

## Args

- `sinceSeq` (int, optional) — cursor.
- `streamFilter` (string, optional) — `stderr` / `stdout` / `logging`.
- `errorsOnly` (bool, optional, default false) — keeps only entries whose content matches an error-like pattern (`exception` / `error` / `stack trace` / `flutter error`, case-insensitive).
- `limit` (int, optional, default 50).

## Returns

```json
{
  "summary": "8 entries (3 stderr, 5 stdout); 2 look like errors",
  "data": {
    "count": 8,
    "nextSeq": 412,
    "entries": [
      {"seq": 404, "ts": "...", "stream": "stdout", "content": "Flutter Error: A RenderFlex overflowed by 42 pixels on the bottom."},
      ...
    ]
  }
}
```

## Pairs well with

- `report_issue` — auto-attaches recent errors.
- `logs` — to correlate glint actions with app output.
- `wait_for_settle` — when you want to see "what printed during the settle window".
