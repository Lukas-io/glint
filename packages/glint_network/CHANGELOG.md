# Changelog

All notable changes to glint_network (called flutter_network_mcp up to 0.11.0) are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.13.2] - 2026-11-08

### Fixed

- `report_issue` no longer names your app, devices or backend hosts; the reply carries `summary` and `redacted` counts.
- The native log stream and helpers are stopped on detach and exit, and the server exits when its parent process is gone.

## [0.13.1] - 2026-10-15

### Changed

- Added an example and cleaned up formatting so the package scores fully on pub.dev.

## [0.13.0] - 2026-10-15

### Changed

- glint_network installs from pub.dev: `dart pub global activate glint_network`. `glint_network update` and the daily update check use the newest pub.dev release (a git install moves over).
- `glint_network install` also builds from a pub.dev install.
- Guides moved from `docs/` to `doc/`; the `glint-network://docs/...` resource URIs are unchanged.
- Usage rollups count older rows toward `avgEstimatedTokens` and `totalEstimatedTokens`, and a ship after an event store reset starts from the first event.

### Fixed

- HTTP made right after a hot restart is captured again instead of being lost for about 20 seconds. (#116)
- Attaching to a VM service that never answers (a suspended or backgrounded app) now fails after 8 seconds instead of waiting forever.
- `report_issue` no longer builds a pre-filled URL too long to open; the full report is saved to a file named in `fullBodyPath`, and the draft asks for the user's go-ahead.
- `glint_network audit verify` no longer calls a log broken when two servers appended at the same moment.

## [0.12.0] - 2026-09-26

### Added

- Guided move off the old names, which stop working on 2026-12-26: installs still using them get one notice with the steps left (MCP instructions, `network_status` warnings, stderr).
- `update` takes over the `flutter_network_mcp` command with `--overwrite` and removes the old package.
- `install` builds from either repository layout and puts the native binary behind both commands.

### Changed

- **Breaking:** flutter_network_mcp is now glint_network and lives in the glint repo; install with `dart pub global activate -s git https://github.com/Lukas-io/glint.git --git-path packages/glint_network`, then `glint_network install`.
- **Breaking:** the command is `glint_network` and `setup` registers the server as `glint-network` (tools appear as `glint-network__<tool>`); `flutter_network_mcp` stays as an alias until 2026-12-26.
- **Breaking:** environment variables are `GLINT_NETWORK_*`; the old `FLUTTER_NETWORK_MCP_*` names still work with a startup warning and are listed by `network_status`.
- Doc resources are now `glint-network://docs/...`, and `report_issue` files to `Lukas-io/glint` with the `network` label.
- Data directory, tool names, arguments and the telemetry endpoint are unchanged, so existing captures and settings carry over.

## [0.11.0] - 2026-09-25

### Added

- `ws_list` and `ws_get` capture WebSocket connections (state, close code, message and byte counts, event timeline) with nothing added to the app; needs Dart 3.13+ and message contents are not captured.
- Older-Dart apps are detected at attach, and `ws_list` says why it is empty. New capability `websockets`.
- `session_configure bodyDecryption` reads AES-CTR app-encrypted bodies (`aes-256-ctr`, `aes-128-ctr`) as plaintext; the key stays in memory and is never stored. (#110, #111)
- Body reads, search, correlate, diff and drift work on decrypted bodies; replay and HAR export keep the original bytes. (#111)
- Automatic backup of `captures.db` before a schema upgrade (`captures.db.pre-v<N>.bak`, old copies deleted after 14 days); skip with `FLUTTER_NETWORK_MCP_NO_MIGRATION_BACKUP=true`.
- Alerts from non-attached sessions expire after 14 days (`FLUTTER_NETWORK_MCP_ALERT_RETENTION_DAYS`, `0` keeps all, or `alerts_config set:{retentionDays:N}`).

### Changed

- Secret header values (authorization, cookies, API keys, `redacted_headers`) are stored as `<redacted>`; `FLUTTER_NETWORK_MCP_STORE_SECRETS=true` keeps them for local replay. (#121)
- **Breaking:** `session_export` redacts by default and masks tokens, JWTs, keys and passwords in bodies; pass `redact:false` for a local-only file. (#121)
- `network_query` masks secret header values and token or password patterns in every text cell. (#121)
- `report_issue` drafts first with `auto:false` and files only with the user's OK, and paths, secrets and crash telemetry messages are redacted. (#121)
- `network_replay redact:false` names the headers that were masked at capture. (#121)
- **Breaking:** telemetry is opt-in: crash reports and usage summaries are sent only with `FLUTTER_NETWORK_MCP_TELEMETRY=on`, and the install id is now random. (#122)
- The license is now Apache-2.0 instead of MIT.
- Added `docs/configuration.md`, `SECURITY.md` and a "Limits today" README section (#124), and refreshed the per-tool guides with new ones for the 0.9.x tools.

### Fixed

- An older build exits with code 78 instead of writing to a newer database. (#123)
- Scope errors carry `errorKind` (`no_session`, `bad_argument`), and every `network_attach` error does too (`bad_argument`, `not_found`, `unresponsive_vm`, `timeout`, `internal`).
- `logs_tail` honours `maxResponseTokens`, takes its own `maxTokens` and reports `budget.dropped`.
- An unknown `severityMin` is `bad_argument` and severities compare case-insensitively.
- `alerts_config` reports `applied` and `rejected` values instead of dropping bad ones silently.
- `network_summarize`, `network_report` and `network_diff_session` no longer count in-flight requests as errors.
- `network_clear` and `socket_clear` fail with `cleared:false` when nothing was cleared and mark partial clears with `partial:true`.
- `set-cookie` is a built-in redacted header, so `session_export redact:true` masks response cookies.
- `network_report` and `network_correlate` hints are corrected (no bogus `hostContains`, earlier request named as likely originator), and several tool descriptions now match the code.
- The same app can no longer be attached twice under two URI spellings; re-attaching returns `alreadyAttached: true`. (#108)
- `network_wait_for_app` returns at once when several apps match or the session cap is hit, treats an attached app as success, and no longer reads a failed DTD probe as the app exiting. (#108)
- A pending body read from a history view is called unrecoverable only after its session has ended. (#108)
- `logs_tail` keeps `developer.log` messages, logger names, errors and stack traces whole; `messageTruncateBytes` counts characters (64 to 65536). (#109)
- A session now ends only when the last server process capturing into it leaves, and `network_detach` sets `stillCapturedByOtherProcess`. (#107)
- Log records are de-duplicated across server processes, and two processes opening the same database no longer fail with `database is locked`. (#107)
- The body flush on detach or app exit keeps to its 3 second deadline. (#106)
- `network_attach` warns when the app was running before attach and returns `preAttachUptimeMs`, since earlier traffic is not recorded.
- Re-evaluating the same source no longer inflates an alert's occurrence count.

## [0.10.0] - 2026-07-02

### Added

- `network_list before:<µs>` pages older results, and `nextCursor` now feeds it.
- `network_get` shows `response.redirects`, and HAR export fills `redirectURL`.
- `session_export redact:true` writes a scrubbed HAR or NDJSON.
- Tool guides and `RESPONSE_CONTRACT.md` are served as MCP resources (`flutter-network://docs/...`), and the `network_query` description embeds the table and column schema.
- Session liveness is live, ended or interrupted in `session_open` and `session_list`, so crashed captures no longer read as live.
- `pendingAlerts` and `network_query` report `scope` (`session` or `all-sessions`).
- `network_attach reattach:true` that matches no earlier session reports `reattachRequested`, `reattachMatched` and `reattachMissReason`.
- `http_anomaly` can be toggled in `alerts_config`.

### Changed

- **Breaking:** `network_replay` defaults to `redact:true` again, since the curl often lands in a transcript; `network_get` redacts auth headers by default (`redact:false` to debug auth) and `network_diff` always does.
- Guidance follows session state: ended and interrupted sessions say "this is its complete capture" instead of "drive the app".
- An agent-initiated attach closes an open `session_open` view with a warning, and scoped reads under a shadowing view say they are reading history.
- `network_summarize` covers the whole session for ended or interrupted sessions instead of the last hour.
- `network_correlate` previews the first 10 matches per session (`matchesShown`, `matchesTotal`).
- URL search also matches the percent-decoded form, so `ÜMLAUT` finds `%C3%9CMLAUT`.
- `network_status` rediscovers a live DTD when the startup URI is stale, and a failed connect points to `network_discover_dtd`.
- Alert titles drop the meaningless `:0` and default ports, and `alerts_config` always matches the real rule set.

### Fixed

- A successful WebSocket upgrade (101) no longer raises a phantom `http_error`.
- A session that attached mid-boot recovers within about 20 seconds instead of staying degraded.
- One bad request no longer drops the rest of a poll's requests.
- A healthy VM answering "no such id" returns `not_found` instead of `unresponsive_vm`.
- Empty `network_list` hints are cursor-aware, and `network_get` paging after semantic truncation points at `offset:0`.
- `updateAvailable` no longer advertises an update to an older version than the one running.

## [0.9.18] - 2026-07-02

### Fixed

- `ignored_hosts` and `capture_allow` changes now reach every attached session, not just a single one.

## [0.9.17] - 2026-07-02

### Fixed

- Captured durations measure the whole exchange instead of only the upload, so `http_slow` fires and p50/p95 in summarize, report and `network_diff_session` are right.
- Every request is searchable (about 14% of historical rows were never indexed), and the no-match warning reports real index coverage.
- A killed app now ends its session (shown as `recentlyEnded` in `network_status`) instead of leaving a zombie attach.
- The server exits when its MCP host closes stdin or sends SIGTERM, instead of leaking orphaned processes.

## [0.9.16] - 2026-06-30

### Added

- `capture_allow` tool (`list`, `add`, `remove`) manages the capture allowlist mid-session, with no restart. (#64)

## [0.9.15] - 2026-06-30

### Security

- The `ignored_hosts action:add` row count now uses a parameterized query.

## [0.9.14] - 2026-06-30

### Added

- `--no-persist` (or `FLUTTER_NETWORK_MCP_NO_PERSIST=true`) keeps captures in memory only and writes nothing to disk; `db_stats` reports `ephemeral:true`. (#64)

## [0.9.13] - 2026-06-30

### Added

- `ignored_hosts` entries with a `/` are `host/path` globs, so one noisy path can be silenced without dropping the whole host. (#64)
- Opt-in allowlist `FLUTTER_NETWORK_MCP_CAPTURE_ALLOW` captures only matching requests; deny still wins, and `ignored_hosts action:list` shows `captureAllowlist`. (#64)

### Fixed

- `ignored_hosts` is documented as a denylist, not an allowlist.

## [0.9.12] - 2026-06-29

### Added

- `captures.db` has a default ~2 GB cap (`FLUTTER_NETWORK_MCP_MAX_DB_BYTES`, `0` or `off` disables) and evicts oldest bodies, then logs, then sessions, never an attached session; `db_stats` reports `sizeCap` and `lastEviction`. (#58)

## [0.9.11] - 2026-06-29

### Changed

- **Breaking:** `network_replay` defaulted `redact` to false so auth debugging shows real tokens; it warns before the curl is shared. (#57)
- `session_export` warns that the file holds unredacted auth headers, cookies and bodies. (#57)

## [0.9.10] - 2026-06-29

### Added

- `network_body_query` searches inside one body with `grep` (regex with context) or `jsonPath` (such as `$.data[*].symbol`) and returns only the matching slices. (#61)

## [0.9.9] - 2026-06-29

### Added

- `network_body_outline` returns a large body's structure (keys, types, array lengths, per-branch byte sizes) without values. (#60)

## [0.9.8] - 2026-06-29

### Fixed

- `network_get` and `network_list` show an unknown size as `sizeKnown:false` instead of a raw `-1`. (#62)

## [0.9.7] - 2026-06-29

### Fixed

- Bodies carry `bodyStatus` (`stored`, `empty`, `pending`, `unavailable`), so a lost body is no longer mistaken for an empty one. (#59)

## [0.9.6] - 2026-06-25

### Fixed

- `network_drift` samples both ends of the timeline, takes a `sinceMs` window and reports `matchedTotal`, so early drift is no longer missed on busy sessions.

## [0.9.5] - 2026-06-25

### Added

- `network_report` triages a session in one call: worst error endpoints, slowest endpoints, pending alerts and a recommended next action.

## [0.9.4] - 2026-06-25

### Added

- `network_replay_as_test` turns a captured request into a runnable Dart test that asserts its status code.

## [0.9.3] - 2026-06-25

### Added

- `network_drift` detects when an endpoint's response JSON shape changes mid-session (fields added, removed or retyped, plus `firstDriftAt`).

## [0.9.2] - 2026-06-25

### Added

- `network_diff_session` compares a session against a baseline by endpoint: new, gone and changed (error rate or p95 latency).

## [0.9.1] - 2026-06-25

### Added

- `network_list` takes a `maxTokens` budget (or a sticky `session_configure maxResponseTokens`) and trims newest-first to fit.

## [0.9.0] - 2026-06-25

### Added

- `usage_stats` shows recovery paths (what the agent does after an error) and `selfCorrection` rates per tool.

## [0.8.15] - 2026-06-25

### Added

- `usage_stats` breaks errors down by `errorKinds`, counts `degraded` calls and ships estimated tokens to the collector.

## [0.8.14] - 2026-06-14

### Added

- `usage_stats` reports `avgEstimatedTokens` and `totalEstimatedTokens` per tool.

## [0.8.13] - 2026-06-13

### Changed

- Tool and parameter descriptions are shorter and consistent, cutting the `tools/list` handshake by about a third.

## [0.8.12] - 2026-06-12

### Changed

- The telemetry collector is live: crash reports and usage rollups are sent to it; opt out with `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` (or `FLUTTER_NETWORK_MCP_NO_USAGE=true` for usage only).

## [0.8.11] - 2026-06-12

### Fixed

- `network_list` no longer says "No HTTP captured yet" when the cursor has advanced; it says "No NEW HTTP" and suggests `since:0`.

## [0.8.10] - 2026-06-12

### Added

- A session id stays stable across a hot restart without calling `network_attach reattach:true`; opt out with `FLUTTER_NETWORK_MCP_NO_AUTO_MIGRATE=true`. (#16)
- `network_status.attached[]` shows `reattachCount`, `lastReattachAtMs` and `previousVmServiceUri`.

## [0.8.9] - 2026-06-12

### Added

- `session_configure` sets sticky default filters that `logs_tail` and `network_list` inherit when an argument is omitted. (#18)

## [0.8.8] - 2026-06-12

### Added

- `logs_tail messageContains` accepts a list of tags, OR-matched. (#15)

## [0.8.7] - 2026-06-12

### Added

- `session_list appNameContains` scopes to one app, and a warning names the apps when a result mixes several. (#27)

### Changed

- Issue templates require the plugin version.

## [0.8.6] - 2026-06-12

### Added

- Usage rollups (per-tool counts, outcomes, latency, tool transitions; no URLs, bodies or argument values) are written to the audit log and auto-shipped at most daily; `flutter_network_mcp usage ship` ships on demand (`--dry-run`, `--json`). (#79)

## [0.8.5] - 2026-06-12

### Added

- `usage_stats` shows per-tool counts, error and empty rates, p50/p95 latency and the busiest tool-to-next-tool pairs (`sinceMs`, `topTransitions`). (#79)

## [0.8.4] - 2026-06-12

### Added

- Local usage capture of tool calls (tool name, argument names only, outcome, duration, size), with nothing shipped; `FLUTTER_NETWORK_MCP_NO_USAGE=true` turns it off. (#79)
- `flutter_network_mcp usage` shows what is stored (`--show`, `--since 7d`, `--json`). (#79)

## [0.8.3] - 2026-06-11

### Added

- `correlate_at` returns the log records and HTTP requests within `±windowMs` of a timestamp, sorted nearest-first with a signed `deltaMs`. (#18)

## [0.8.2] - 2026-06-11

### Added

- `network_attach reattach:true` keeps one stable `sessionId` for the same app and device across hot restarts, and `network_status.attached[]` shows `lastReattachAtMs`. (#16)

## [0.8.1] - 2026-06-11

### Added

- `logs_tail messageContains` filters by message text on the server. (#15)
- The log ring buffer size is configurable (`FLUTTER_NETWORK_MCP_LOG_BUFFER`, 50 to 10000, default 500, or `network_attach logBufferSize`), and `network_status.attached[]` shows `logBufferUsed` and `logBufferCapacity`. (#21)

### Changed

- The server instructions now say when and how an agent should offer to file feedback. (#20)

## [0.8.0] - 2026-06-11

### Changed

- `network_attach` and `network_status.attached[]` report per-session capability health, with `degraded` listing capabilities that failed to start. (#17)

### Fixed

- Chunked and gzip response bodies are no longer stranded as `response: null`, and `network_search` can see them. (#13)
- `network_attach appNameContains` resolves across all discovered DTDs instead of only the default one. (#14)

## [0.7.4] - 2026-06-04

### Added

- `auto_attach_config` (`list`, `add`, `remove`, `clear`) persists the auto-attach allow and deny lists to `<data-dir>/auto-attach.json`; env vars and flags still override it, and the agent must ask the user first.
- `flutter_network_mcp setup` is an interactive first-run wizard that scaffolds the Claude Code MCP entry, offers auto-attach for running apps and offers `install`.

## [0.7.3] - 2026-06-04

### Added

- `http_anomaly` and `http_anomaly_errors` alerts flag an endpoint whose p95 latency doubles or error rate jumps against its own recent baseline; turn off with `alerts_config rules.http_anomaly:false`.
- `network_status` shows a `continuation` block and a reattach `nextStep` after a host restart, from a saved `last-session.json`; an explicit detach clears it.

## [0.7.2] - 2026-06-04

### Added

- `report_issue` files a `bug` or `ux` issue against this MCP (via `gh`, or a pre-filled URL), labelled `agent-filed` and with paths redacted.
- `alerts_drain` and `alerts_peek` show `priorOccurrences`: past sessions where the same alert fired, with their notes.

## [0.7.1] - 2026-06-04

### Added

- Crash telemetry is on by default and recorded first in a hash-chained local audit log; opt out with `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`. Payloads hold no paths, URLs, bodies or tokens.
- `flutter_network_mcp audit verify` checks the log chain (exit code 70 if broken), and `audit show` prints entries (`--since 7d`, `--signature`).
- The binary writes the audit log but does not send reports yet, since no collector is configured.

## [0.7.0] - 2026-06-04

### Added

- `network_summarize` gives one digest row per endpoint (`method`, `host`, ids collapsed): count, status distribution, p50/p95 latency and error rate (`sinceMs`, `hostContains`, `limit`, `minCount`).
- `network_get` truncates JSON (arrays past 5 elements, long strings) and HTML (scripts, styles) by structure, reports `truncationMode`, and keeps the byte cap; `network_diff`, `network_body` and HAR export stay byte-exact.

## [0.6.3] - 2026-06-04

### Added

- Alerts are deduplicated by signature: a burst of the same issue is one alert with `occurrenceCount`, `firstSeenMs`, `lastSeenMs`, `lastSourceId` and `signature`, at the highest severity seen. Draining resets the count.

### Changed

- `network_status.alerts` shows `pendingTotal` (distinct alerts) and `pendingEvents` (raw event count).

## [0.6.2] - 2026-06-03

### Added

- DTD auto-discovery at startup from the standard `package:dtd` discovery files, so no URI needs pasting; disable with `FLUTTER_NETWORK_MCP_AUTO_DISCOVER_DTD=false` or `--no-auto-discover-dtd`.
- `network_discover_dtd` lists live DTDs ranked by relevance (`cwdMatch`, `includeStale`, `limit`) with a recommended URI.
- `flutter_network_mcp install` replaces the slow JIT wrapper with a native binary, and `update` re-runs activation and the native build; `FLUTTER_NETWORK_MCP_NO_JIT_NUDGE=true` silences the JIT hint.
- `network_status.knownApps` lists apps across every running DTD, each with `dtdUri` and `workspaceRoot`, and auto-attach works across DTDs.
- A daily startup version check prints one stderr nudge when a newer release exists (`FLUTTER_NETWORK_MCP_NO_UPDATE_CHECK=true` skips it).
- `network_status` carries an `mcp` block with `version`, `commit`, `isAot`, `upgradeCommand` and `updateAvailable`.
- `network_attach` returns `autoAttachSuggestion` for apps not on the auto-attach allowlist, and the agent must ask the user before changing anything.

### Changed

- Auto-attach evaluates already-running apps against the allowlist on its first tick instead of skipping them.
- `network_status` nextSteps use DTD discovery instead of asking the user for a URI.
- The README explains that every CLI flag has an environment-variable fallback, so no `claude mcp remove` and `add` cycle is needed.

## [0.6.1] - 2026-05-28

### Fixed

- Auto-attach is hardened: overlapping ticks no longer race, a failing tick no longer stops the watcher, and the known-URI set is bounded.
- A database that fails to open exits with code 70 and a `--data-dir` recovery hint instead of a raw stack trace.
- Log stream errors are logged to stderr instead of killing the logging subsystem.

### Security

- **Breaking:** `--auto-attach` and `FLUTTER_NETWORK_MCP_AUTO_ATTACH` now require a comma-separated allowlist of app name substrings (`--auto-attach=app1,app2`), and the bare boolean form no longer enables anything.
- `--auto-attach-deny` and `FLUTTER_NETWORK_MCP_AUTO_ATTACH_DENY` exclude apps or devices even when the allowlist admits them (deny wins).

## [0.6.0] - 2026-05-28

### Added

- Multi-attach: hold several attached sessions at once (`FLUTTER_NETWORK_MCP_MAX_ATTACH`, default 4, 1 to 32); read tools take `sessionId` or `appNameContains`, and with 2+ attached and no scope they list the sessions to pick from.
- `network_detach` takes `sessionId`, `appNameContains` or `all:true`, and `network_status.attached` is a list with `attachedCount` and per-session pending alerts.
- `--auto-attach` (or `FLUTTER_NETWORK_MCP_AUTO_ATTACH`, poll interval `FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS`) attaches apps that start after the server, and respects manual detach and the attach cap.
- HTTP, sockets and logs are captured from every isolate of an app, tagged with `isolateId`, and read tools accept an `isolateId` filter.
- `network_correlate` pairs a request in one session with its webhook in another by shared content (`sessionIds`, `pattern`, `timeWindowMs`).

### Changed

- **Breaking:** `network_attach` drops `force:true`; the same app cannot be attached twice, but different apps coexist.
- **Breaking:** `alerts_clear` is scoped to one session instead of all sessions.
- `pendingAlerts` on a response counts only the calling tool's session.

## [0.5.18] - 2026-05-24

### Added

- The README tool table has a when-to-use line per tool, and issue templates are lighter with a new UX friction template.

### Changed

- Descriptions of eight tools (including `network_status`, `network_attach`, `network_search`, `network_diff`, `network_query`, `network_body`, `logs_tail`, `db_stats`) now lead with when to use them.

## [0.5.17] - 2026-05-24

### Added

- The server instructions tell agents to file a bug report or hand the user a paste-ready body when they hit a bug or confusing output.

## [0.5.16] - 2026-05-24

### Added

- `FLUTTER_NETWORK_MCP_DATA_DIR` sets the data directory, like `--data-dir`.

### Changed

- The macOS default data directory is now `~/Library/Application Support/flutter_network_mcp`; existing data moves there once, automatically.

### Fixed

- A fresh install no longer crashes when the default data directory is unwritable: it falls back to the next writable location, or exits with code 73 and one actionable line.

## [0.5.15] - 2026-05-22

### Changed

- Every successful tool response carries `pendingAlerts: {count, critical?}` when undrained alerts exist, so agents no longer poll `network_status` for them.

## [0.5.14] - 2026-05-22

### Changed

- `docs/tools/` is reorganized into 11 use-case folders, each with its own README.

## [0.5.13] - 2026-05-22

### Changed

- Corrected stale README details, restructured `docs/README.md` by use case, and added an "agent-facing contract" README section and a bug-report issue template.

## [0.5.12] - 2026-05-22

### Changed

- `network_query`, `ignored_hosts`, `redacted_headers`, `db_stats`, `db_vacuum` and `bodies_purge` replies gain `summary`, `warnings` and `nextSteps`, and `bodies_purge` dry-run reports `wouldPurgeRows` and `wouldPurgeBytes`.

## [0.5.11] - 2026-05-22

### Changed

- The six session tools reply with `summary`, `warnings` and `nextSteps`, and the `session_delete` dry-run lists per-type counts.

### Fixed

- `session_delete` dry-run and `session_export` no longer report every per-session count as 0.

## [0.5.10] - 2026-05-22

### Changed

- **Breaking:** `alerts_clear` with `drainedOnly:false` now requires `confirm:true`, and reports `remainingPending`.
- `alerts_drain`, `alerts_peek`, `alerts_config` and `alert_patterns` replies gain per-severity summaries, `warnings` and `nextSteps`, and errors carry concrete recovery steps.

## [0.5.9] - 2026-05-22

### Changed

- `logs_tail` reports `severeCount`, filters in its summary, and warnings for rotation and no matches; `logs_clear` reports `clearedCount`.

## [0.5.8] - 2026-05-22

### Changed

- `socket_list`, `socket_get` and `socket_clear` replies gain `summary`, `warnings` and `nextSteps`, and errors carry recovery steps.

## [0.5.7] - 2026-05-22

### Changed

- `network_body`, `network_clear`, `network_diff`, `network_replay`, `network_detach` and `network_search` replies gain `summary`, `warnings` and `nextSteps`, and errors share one `{error, nextSteps}` shape.
- `network_diff` omits unchanged `statusDiff`, `methodDiff` and `urlDiff` and rejects `idA == idB`.
- `network_detach` reports the rows captured in the session it ended.

## [0.5.6] - 2026-05-22

### Changed

- `network_get` gains `summary`, capability-aware `nextSteps`, `warnings` and recovery steps on errors, and omits null fields.
- **Breaking:** the lifecycle `events` array in `network_get` is now opt-in with `includeEvents:true` and capped at 50 entries.

## [0.5.5] - 2026-05-22

### Changed

- `network_list` gains `summary`, capability-aware `nextSteps` and `warnings`, and omits null fields per row.

## [0.5.4] - 2026-05-22

### Changed

- `network_attach` gains `summary` and `warnings`, suggests only enabled tools, skips disabled capture paths, and its no-DTD-URI error asks the user for the URI.

### Removed

- `network_attach` no longer returns `httpProfilingEnabled`, `logStreamActive` or `capturesDbPath`.

## [0.5.3] - 2026-05-22

### Changed

- `network_attach appNameContains` filters apps by name when DTD has several.
- **Breaking:** `network_attach` while already attached now errors with `currentApp` and `liveSessionId`; pass `force:true` for the old behaviour.
- `network_status attachIfOne` auto-attaches when exactly one app is visible, and attach errors carry `nextSteps`.

## [0.5.2] - 2026-05-22

### Fixed

- `dart pub global activate` no longer fails with "Could not find bin/flutter_network_mcp.dart".

## [0.5.1] - 2026-05-22

### Changed

- `network_status` connects to DTD on the first call (`connectDtd:false` for passive checks), shows `dbPath` and `sessionCount`, and gives context-aware `nextSteps`.
- `network_status` splits alert counts into `pendingCurrent`, `pendingTotal` and `critical`, and reports capabilities as `"all"` when every category is on.

## [0.5.0] - 2026-05-21

### Added

- Storage tools `session_delete` (cascade, dry-run), `bodies_purge`, `db_stats`, `db_vacuum` and `alerts_clear`.
- `redacted_headers` extends the replay redaction set, and `alert_patterns` adds custom regex alert rules.
- `FLUTTER_NETWORK_MCP_POLL_MS` (50 to 60000) and `FLUTTER_NETWORK_MCP_LOG_BUFFER` (50 to 10000) startup knobs.

### Changed

- `network_get` takes `headerTruncateBytes` (default 256) and `network_diff` takes `maxLineLength` (default 2000).
- `network_replay` truncates the body by default (`bodyTruncateBytes`, default 4096) and uses the runtime redacted-header set.
- `network_query` no longer collides with a user `LIMIT`, and returns BLOB and long string cells as size summaries.
- `network_search` indexes more JSON content types.

## [0.4.0] - 2026-05-21

### Added

- `network_search` full-text search over URLs and bodies with BM25 ranking and highlighted snippets.
- Live alerts: `alerts_drain`, `alerts_peek` and `alerts_config` with `http_5xx`, `http_4xx`, `http_error`, `http_slow`, `log_keyword` and `flutter_error` rules.
- `--capabilities` allowlist and `--disable` denylist hide tools and capture paths by category.
- `network_diff`, `network_replay` (curl with auth redaction), `session_note` and `ignored_hosts`.
- Per-tool docs in `docs/tools/` and a `network_status` report of active capabilities and pending alerts.
- `network_attach` times out after 5 seconds on a stale DTD with a clear error instead of hanging.

## [0.3.0] - 2026-05-21

### Added

- Captures persist in SQLite (`captures.db`, `--data-dir` to move it): HTTP with bodies, socket events and logs.
- Read tools query the live VM, or the database after `session_open`.
- `session_list`, `session_open`, `session_close` and `session_export` (HAR 1.2 or NDJSON).
- `network_query` runs read-only `SELECT` queries with a 500-row cap.

## [0.2.0] - 2026-05-21

### Added

- `network_list` cursors and filters (`since`, `method[]`, `hostContains`, `statusMin`, `statusMax`, `limit`).
- `network_get` truncates bodies (`bodyTruncateBytes`, default 4 KB), and `network_body` fetches byte ranges with `nextOffset` paging.
- Socket tools `socket_list`, `socket_get` and `socket_clear`.
- Log stream capture with `logs_tail` and `logs_clear`.

## [0.1.0] - 2026-05-21

### Added

- Initial stdio MCP server with `network_status`, `network_attach`, `network_list`, `network_get` and `network_detach`.
