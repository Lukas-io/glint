---
tool: logs
description: Glint's own action log — one row per tool call (tap, swipe, type, etc.), with outcome and elapsed time.
when_to_use: Reconstructing what the agent just did, debugging a sequence of actions, attaching context to a bug report.
---

## DO NOT USE THIS TOOL WHEN

- You want logs from the *app itself* — that's `app_logs` (stderr / stdout / `developer.log`). `logs` is glint's view of glint.
- You want privacy-safe rollups — that's `telemetry op:"token_usage"`.
- You're trying to find when the user tapped X *in the app* — glint only sees what the agent did via MCP tools; user taps on the real device aren't recorded.

## Use this when

- You're filing a `bug` via `report_issue` (the tool auto-attaches the last 30 entries; reading them yourself helps you describe the sequence).
- You're recovering from a confusing state and want to know "what was the last tool I called and did it succeed?"
- You're tuning your own loop and want to see latency per call.

## How it works

In-memory ring buffer (default 200 entries). Survives detach + re-attach. Each entry holds: sequence id, timestamp, tool name, outcome (`ok` / `error`), elapsed ms, summary, args (scrubbed of long values like `vmUri`), error kind + detail on failures, armed metadata when present.

## Args

- `sinceSeq` (int, optional) — cursor; only entries with `sequence > sinceSeq`.
- `errorsOnly` (bool, optional, default false).
- `limit` (int, optional, default 50, max 200).

## Returns

```json
{
  "summary": "12 entries (seq 41–52); 2 errors",
  "data": {
    "count": 12,
    "nextSeq": 53,
    "entries": [
      {"seq": 41, "ts": "...", "tool": "tap", "outcome": "ok", "elapsedMs": 87, "summary": "tapped sign_out_button"},
      {"seq": 42, "ts": "...", "tool": "wait_for_settle", "outcome": "ok", "elapsedMs": 1150, "summary": "settled in 1150ms"}
    ]
  }
}
```

## Pairs well with

- `report_issue` — auto-attaches the recent log.
- `app_logs` — for the app's own output during the same window.
