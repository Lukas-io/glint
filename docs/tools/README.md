# Tool reference for agents

Per-tool guidance for `glint`. Tools are organized in `tools/<category>/` subfolders. Each detailed page has a **DO NOT USE THIS TOOL WHEN** section at the top — negative flags catch ~70% of misuse before it happens; read them first.

The index below is by **use case** ("I want to do X — which tool?"). Some tools serve more than one job and appear under more than one section; the physical file lives in its primary category folder.

> **Filing issues is agent-first.** When something breaks or feels off in this MCP — wrong output, missing field, slow, confusing, awkward — call `report_issue`. Three types: **`bug`** (wrong output / crash), **`ux`** (awkward / confusing / slow), **`feature`** (capability that's missing). The tool tries `gh issue create` first and falls back to a pre-filled GitHub deep link. Title + body + attached action-log are path-redacted before submission. Don't wait for the user to ask.

> **Stable addressing.** Every actionable widget in `get_scene` has a `glintId` like `floating_action_button` or `elevated_button_in_flags_lab`. Same widget at the same source location → same id every read. Duplicate siblings get a `#xxxx` disambiguator (`text_in_list#tso5`); prefer the un-suffixed id when present. Coordinates exist as an escape hatch but are rarely needed.

> **Armed intent.** Any targeted tool can take `awaitReady: true` plus an optional `readyTimeoutMs` (default 5000). The server polls until the target exists in the tree AND passes a hit test, then fires. Use this to chain actions across screen transitions without the agent burning a round-trip on `wait_for_settle`.

---

## Use cases

### [Getting started — first call of any session](lifecycle/)

- [`attach`](lifecycle/attach.md) — connect to a running Flutter app's VM service and bind a device target.
- [`session`](lifecycle/session.md) — inspect attach state, list past sessions, detach.
- [`report_issue`](observability/report_issue.md) — file a bug / ux / feature note. `gh` CLI or pre-filled deep link.

### [Reading the scene](perception/)

- [`get_scene`](perception/get_scene.md) — the live perception scene as a compact tree. Read this before every action.
- [`resolve`](perception/resolve.md) — turn a `glintId` into logical / physical coordinates without acting.
- [`wait_for_settle`](perception/wait_for_settle.md) — block until frames quiet + loading affordances clear.

### [Driving the app](interaction/)

- [`tap`](interaction/tap.md) — single tap on a tappable target.
- `long_press` — press-and-hold with a configurable duration.
- `swipe` — a directional flick (no target → screen-anchored; with target → from-this-widget).
- `drag` — start at a target, end at another or at coordinates.
- `scroll` — scroll a specific scrollable by direction + distance.
- [`scroll_to_find`](interaction/scroll_to_find.md) — scroll until a glintId / content predicate becomes hittable.
- [`type`](interaction/type.md) — focus a typeable target and emit text.
- `hardware_button` — home / back / volume / face-id / lock (iOS-first).

### [Confirming the result](perception/)

- `get_scene` again — the framework is the source of truth, not your prediction.
- [`wait_for_settle`](perception/wait_for_settle.md) — for transitions / async work.

### [Diagnostics](observability/)

- [`logs`](observability/logs.md) — glint's own action log (one row per tool call).
- [`app_logs`](observability/app_logs.md) — the running app's stderr / stdout / `developer.log`.
- [`telemetry`](observability/telemetry.md) — status, token usage, audit log, ship rollup.
- `config` — read / write per-session defaults (default device, timeout caps).

---

## Workflow

1. `attach` once at session start.
2. `get_scene` to read what's on screen.
3. Act with a `glintId` from the scene. The marker on each line tells you what works:
   - `*` tappable → `tap`, `long_press`, `double_tap`, `drag`
   - `>` typeable → `type`
   - `<>` scrollable → `scroll`, `swipe`, `scroll_to_find`
   - `-` static → read-only
4. `get_scene` again to confirm.

---

## Recovery

Failures carry `errorKind` in `structuredContent`:

- `unresolvedTarget` — no such glintId. `get_scene`, pick a real id.
- `notHittable` — covered by overlay/absorber. Dismiss, retry.
- `targetNeverReady` — armed ceiling hit; target appeared but stayed unhittable. Raise `readyTimeoutMs` or dismiss the cover.
- `unsupportedBackendAction` — not wired on this platform.
- `backendToolError` — native tool exited non-zero; read `detail`.
- `geometryResolveError` — inspector eval failed. Retry; else `get_scene` and try a sibling id.
- `sessionNotAttached` — call `attach` first.
- `invalidArgument` — message says what to fix.
- `internal` — file a `bug` via `report_issue`.

---

## Context-budget rules (the server enforces these)

- **`get_scene` is compressed.** Brackets and homogeneous runs collapse. The output is addressable; if you need raw geometry, call `resolve`.
- **`logs` / `app_logs` use cursors.** Pass `sinceSeq` to avoid re-fetching.
- **Every response is `{summary, ..., nextSteps, [warnings]}`** — branch on these instead of re-asking the server. Errors use the same shape.

---

## Capability matrix

Glint v0 has no `--capabilities` / `--disable` flags. Every tool is always on. The categories below map to the source modules:

| Category | Tools |
|---|---|
| `lifecycle` | `attach`, `session` |
| `perception` | `get_scene`, `resolve`, `wait_for_settle` |
| `interaction` | `tap`, `long_press`, `swipe`, `drag`, `scroll`, `scroll_to_find`, `type`, `hardware_button` |
| `observability` | `logs`, `app_logs`, `config`, `telemetry`, `report_issue` |

---

## See also

- [`docs/CRASH_REPORTING.md`](../CRASH_REPORTING.md) — what crash telemetry collects + how to opt out.
