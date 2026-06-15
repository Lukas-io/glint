---
tool: telemetry
description: Inspect or trigger glint's telemetry pipeline (status, ship, token usage, audit log).
when_to_use: Showing the user what's been recorded, verifying opt-out, surfacing an update, debugging telemetry itself.
---

## DO NOT USE THIS TOOL WHEN

- You want to silence telemetry — that's an env var (`GLINT_NO_TELEMETRY=true` or `GLINT_NO_USAGE=true`), not a tool call.
- You're trying to read the *app*'s logs — that's `app_logs`.
- You want glint's action log (which tool fired when) — that's `logs`.

## Use this when

- The user asks "what does glint know about my usage?" → `op:"audit_show"` shows the exact JSON that's been (or would have been) shipped.
- You want to know whether the running install is current → `op:"status"` reports `updateAvailable` + `latest`.
- You want a sense of context cost → `op:"token_usage"` estimates tokens by tool.
- You want to manually trigger a rollup ship (e.g. before a long pause).

## Ops

### `status` (default)

Returns the running install's state: glint version, commit, AOT-vs-JIT, telemetry / usage opt-out flags, recorder size, data dir, collector endpoint, and `updateAvailable` if the daily probe found a newer version.

### `ship`

Builds the rollup payload from every event newer than the watermark, writes it to the audit log, POSTs to the collector. Idempotent — re-running never double-counts (watermark advances on success).

### `dryRun`

Like `ship` but doesn't post or advance the watermark. Returns the exact JSON that *would* ship. Useful when explaining telemetry to a privacy-conscious user.

### `token_usage`

Estimates the agent-side token cost of glint's responses, computed as `resultBytes / 4` from the recorder. Returns total, per-tool breakdown (count / total / avg / max), and the top-N largest single responses. The estimation note in the response flags that real model tokenization may differ.

### `audit_show`

Pretty-prints the most recent N entries of the hash-chained audit log. Each entry is a JSON payload that was (or would have been) shipped. Lets the user see byte-for-byte what was sent.

### `audit_verify`

Walks the audit log line by line, recomputing each `this_hash` and verifying each line's `prev_hash` matches the previous line's `this_hash`. Returns `intact: true` on a clean chain, or `intact: false` with the broken entry index + reason.

## Args

- `op` (string, optional, default `status`) — one of `status`, `ship`, `dryRun`, `token_usage`, `audit_show`, `audit_verify`.
- `limit` (int, optional) — for `audit_show` / `token_usage`. Defaults: 20 / 10.
- `sinceId` (int, optional) — for `token_usage`; only count events with `id > sinceId`.

## Returns

`status`:
```json
{
  "summary": "glint: 0.0.1 (commit a9edd0a) [JIT]\ntelemetry: enabled\nusage:     enabled\nrecorder:  17 event(s) ...\nupdate:    v0.0.2 available — run `glint update`",
  "data": {
    "glintVersion": "0.0.1",
    "isAot": false,
    "telemetryDisabled": false,
    "updateAvailable": true,
    "updateStatus": {"current": "0.0.1", "latest": "0.0.2", ...}
  }
}
```

`token_usage`:
```json
{
  "summary": "~3120 tokens across 17 call(s) (est. resultBytes/4)\ntop tools:\n  get_scene           5x   1840 tok  (avg 368, max 712)\n  tap                 7x    560 tok  ...",
  "data": {
    "totalEvents": 17,
    "totalEstimatedTokens": 3120,
    "perTool": [...],
    "topResponses": [...],
    "estimationNote": "tokens estimated as resultBytes / 4.0; real model tokenization will differ."
  }
}
```

## Pairs well with

- `report_issue` — when the audit log shows something the user wants to flag.
- `logs` / `app_logs` — for the human-readable side of the same window.
