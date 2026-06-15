---
tool: report_issue
description: File a glint bug / ux / feature note from inside the agent turn. `gh` CLI if available, pre-filled GitHub deep link otherwise.
when_to_use: Any time something feels off — wrong output, missing field, slow, confusing, awkward. Big or small. Don't wait for the user to ask.
---

## DO NOT USE THIS TOOL WHEN

- The user is mid-task and would be disrupted — wait for a natural pause.
- You don't have a concrete repro or a specific friction point — generic "glint was great today" is noise.
- You're trying to ping the maintainer about *your* code — this is for issues with glint itself.
- The "issue" is a question the docs already answer — read `docs/tools/README.md` first.

## Use this when

- A tool errored when you expected success and the cause is glint, not the user's app.
- A scene element classified wrong (`*` on something that isn't tappable, or vice versa).
- A response field is missing / off / ambiguous and you had to work around it.
- The user expressed friction ("why did it not...", "I wish it...", "this is annoying").
- A non-trivial debugging session finished and you noticed something worth filing.

## How to offer

One short line: "That [friction / workaround] would help the glint maintainer. Want me to file a quick issue? I'll draft it; you just approve."

On yes, call the tool. Don't file without consent.

## How it works

1. Path-redacts title, body, and the auto-attached context. `/Users/<name>/StudioProjects/<project>/…` becomes `<project:…>/…` or `<home>/…` before anything leaves the machine.
2. Composes the body: your text + the last 30 entries from `logs` (action log) + up to 10 entries from `app_logs` filtered to errors-only.
3. Tries `gh issue create` with the typed label. Success → returns the URL.
4. On `gh` failure (not installed, not authed, exited non-zero), returns a `github.com/Lukas-io/glint/issues/new?title=…&body=…&labels=…` deep link the user opens in one click.

## Args

- `type` (string, required) — `bug` / `ux` / `feature`. Picks the label set.
- `title` (string, required) — one-line summary. Redacted.
- `body` (string, required) — what happened, what you expected, repro steps. Redacted.
- `includeContext` (bool, optional, default true) — attach action log + app errors.
- `dryRun` (bool, optional, default false) — compose + return without filing.

## Labels

| `type` | labels applied |
|---|---|
| `bug` | `bug`, `agent-filed` |
| `ux` | `ux-friction`, `agent-filed` |
| `feature` | `enhancement`, `agent-filed` |

`agent-filed` lets the maintainer filter MCP-originated reports.

## Returns

Filed via gh:
```json
{
  "summary": "filed: https://github.com/Lukas-io/glint/issues/42",
  "data": {
    "filed": true,
    "method": "gh-cli",
    "url": "https://github.com/Lukas-io/glint/issues/42",
    "type": "bug",
    "labels": ["bug", "agent-filed"]
  }
}
```

Filed via deep link:
```json
{
  "summary": "gh CLI unavailable; open this pre-filled URL instead:\n\nhttps://github.com/Lukas-io/glint/issues/new?title=…",
  "data": {
    "filed": false,
    "method": "paste-ready",
    "deepLink": "https://github.com/Lukas-io/glint/issues/new?...",
    "pasteBody": "..."
  },
  "warnings": ["unavailable (...)"]
}
```

## Pairs well with

- `logs` / `app_logs` — already auto-attached; reading them first helps you write a tighter body.
- `telemetry op:"status"` — version + commit live there; cite them in the body when relevant.
