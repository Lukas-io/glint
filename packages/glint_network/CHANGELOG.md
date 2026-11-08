# Changelog

Versions follow semver; before 1.0 a minor bump may break things.

## [Unreleased]

- Shortens the changelog to one row per change.

## [0.13.2] - 2026-11-08

- Fixes `report_issue` naming your app, devices or backend hosts.
- Fixes native log streams and helpers lingering after detach and exit.

## [0.13.1] - 2026-10-15

- Improves pub.dev scoring with an example and cleaner formatting.

## [0.13.0] - 2026-10-15

- Adds install from pub.dev with `dart pub global activate glint_network`.
- Changes `update` and the daily update check to follow the newest pub.dev release.
- Changes guides to `doc/`; the `glint-network://docs/...` URIs are unchanged.
- Fixes HTTP made right after a hot restart being lost for about 20 seconds. (#116)
- Fixes `network_attach` waiting forever on a VM service that never answers.
- Fixes `report_issue` URLs too long to open; the full report goes to `fullBodyPath`.
- Fixes `glint_network audit verify` calling a log broken after simultaneous appends.
- Fixes usage rollups after an event store reset.

## [0.12.0] - 2026-09-26

- Adds a one-time notice for installs still on the old names, which stop working on 2026-12-26.
- Adds `update --overwrite` to take over the `flutter_network_mcp` command.
- Adds `install` from either repository layout.
- Changes docs resources to `glint-network://docs/...` and `report_issue` to file to the glint repo.
- **Breaking:** Renames flutter_network_mcp to glint_network; reinstall from the glint repo.
- **Breaking:** Renames the command to `glint_network` and the server to `glint-network`.
- **Breaking:** Renames environment variables to `GLINT_NETWORK_*`; old names still warn.

## [0.11.0] - 2026-09-25

- Adds `ws_list` and `ws_get` for WebSocket capture with nothing added to the app.
- Adds `session_configure bodyDecryption` to read AES-CTR encrypted bodies. (#110, #111)
- Adds a `captures.db` backup before a schema upgrade, and 14-day expiry for old alerts.
- Changes secret headers to be stored as `<redacted>`, and `network_query` to mask secrets. (#121)
- Changes `report_issue` to draft first and redact paths and secrets. (#121)
- Changes the license to Apache-2.0.
- Fixes duplicate attaches, `database is locked` and early session ends. (#107, #108, #106, #123)
- Fixes `logs_tail` dropping `developer.log` details, and its token budget. (#109)
- Fixes replies and errorKinds of `alerts_config`, `network_clear` and `network_summarize`.
- **Breaking:** Redacts `session_export` by default; pass `redact:false` to keep it. (#121)
- **Breaking:** Makes telemetry opt-in with `FLUTTER_NETWORK_MCP_TELEMETRY=on`. (#122)

## [0.10.0] - 2026-07-02

- Adds `network_list before:` paging, `response.redirects` and `session_export redact:true`.
- Adds tool guides as MCP resources and the table schema in the `network_query` description.
- Adds live, ended and interrupted session states to `session_open` and `session_list`.
- Adds `scope` to `pendingAlerts` and `network_query`, and `http_anomaly` to `alerts_config`.
- Changes guidance, `network_summarize` and `network_correlate` to follow session state.
- Improves URL search and `network_status` recovery from a stale DTD.
- Fixes phantom `http_error` on WebSocket upgrades and slow recovery of mid-boot attaches.
- Fixes `not_found` reported as `unresponsive_vm` and several empty-result hints.
- **Breaking:** Defaults `network_replay` and `network_get` to `redact:true`.

## [0.9.18] - 2026-07-02

- Fixes `ignored_hosts` and `capture_allow` changes reaching only one attached session.

## [0.9.17] - 2026-07-02

- Fixes captured durations, so `http_slow` and p50/p95 are right.
- Fixes about 14% of historical requests never being searchable.
- Fixes a killed app leaving a zombie attach.
- Fixes the server leaking processes when its MCP host closes.

## [0.9.16] - 2026-06-30

- Adds the `capture_allow` tool to manage the capture allowlist mid-session. (#64)

## [0.9.15] - 2026-06-30

- Fixes `ignored_hosts action:add` row counts to use a parameterized query.

## [0.9.14] - 2026-06-30

- Adds `--no-persist` to keep captures in memory only. (#64)

## [0.9.13] - 2026-06-30

- Adds `host/path` globs to `ignored_hosts`, and an opt-in capture allowlist. (#64)
- Fixes `ignored_hosts` being documented as an allowlist.

## [0.9.12] - 2026-06-29

- Adds a default ~2 GB cap on `captures.db` that evicts oldest data first. (#58)

## [0.9.11] - 2026-06-29

- Changes `session_export` to warn that the file holds unredacted data. (#57)
- **Breaking:** Defaults `network_replay` to `redact:false` and warns before sharing. (#57)

## [0.9.10] - 2026-06-29

- Adds `network_body_query` to search inside one body by `grep` or `jsonPath`. (#61)

## [0.9.9] - 2026-06-29

- Adds `network_body_outline` to show a large body's structure without values. (#60)

## [0.9.8] - 2026-06-29

- Fixes `network_get` and `network_list` showing an unknown size as `-1`. (#62)

## [0.9.7] - 2026-06-29

- Fixes lost bodies being mistaken for empty ones with `bodyStatus`. (#59)

## [0.9.6] - 2026-06-25

- Fixes `network_drift` missing early drift on busy sessions.

## [0.9.5] - 2026-06-25

- Adds `network_report` to triage a session in one call.

## [0.9.4] - 2026-06-25

- Adds `network_replay_as_test` to turn a request into a runnable Dart test.

## [0.9.3] - 2026-06-25

- Adds `network_drift` to detect an endpoint's response shape changing mid-session.

## [0.9.2] - 2026-06-25

- Adds `network_diff_session` to compare a session against a baseline by endpoint.

## [0.9.1] - 2026-06-25

- Adds a `maxTokens` budget to `network_list`.

## [0.9.0] - 2026-06-25

- Adds recovery paths and `selfCorrection` rates to `usage_stats`.

## [0.8.15] - 2026-06-25

- Adds `errorKinds`, `degraded` counts and estimated tokens to `usage_stats`.

## [0.8.14] - 2026-06-14

- Adds token estimates per tool to `usage_stats`.

## [0.8.13] - 2026-06-13

- Improves tool descriptions, cutting the `tools/list` handshake by about a third.

## [0.8.12] - 2026-06-12

- Changes telemetry to send crash reports and usage rollups to the live collector.

## [0.8.11] - 2026-06-12

- Fixes `network_list` saying "No HTTP captured yet" when the cursor has advanced.

## [0.8.10] - 2026-06-12

- Adds session ids that stay stable across a hot restart without `reattach:true`. (#16)
- Adds `reattachCount` and `previousVmServiceUri` to `network_status.attached[]`.

## [0.8.9] - 2026-06-12

- Adds `session_configure` sticky default filters for `logs_tail` and `network_list`. (#18)

## [0.8.8] - 2026-06-12

- Adds a list of tags to `logs_tail messageContains`. (#15)

## [0.8.7] - 2026-06-12

- Adds `session_list appNameContains` to scope to one app. (#27)
- Changes issue templates to require the plugin version.

## [0.8.6] - 2026-06-12

- Adds daily auto-shipped usage rollups and `usage ship` to send them on demand. (#79)

## [0.8.5] - 2026-06-12

- Adds `usage_stats` with per-tool counts, error rates and p50/p95 latency. (#79)

## [0.8.4] - 2026-06-12

- Adds local usage capture of tool calls, with nothing shipped. (#79)
- Adds the `usage` command to show what is stored. (#79)

## [0.8.3] - 2026-06-11

- Adds `correlate_at` to find logs and requests near a timestamp. (#18)

## [0.8.2] - 2026-06-11

- Adds `network_attach reattach:true` to keep one `sessionId` across hot restarts. (#16)

## [0.8.1] - 2026-06-11

- Adds `logs_tail messageContains` to filter by message text. (#15)
- Adds a configurable log buffer size and its usage in `network_status.attached[]`. (#21)
- Changes the server instructions to say when to offer filing feedback. (#20)

## [0.8.0] - 2026-06-11

- Adds per-session capability health, with `degraded` listing failed capabilities. (#17)
- Fixes chunked and gzip bodies stranded as `response: null`. (#13)
- Fixes `network_attach appNameContains` resolving only the default DTD. (#14)

## [0.7.4] - 2026-06-04

- Adds `auto_attach_config` to persist the auto-attach allow and deny lists.
- Adds `setup`, an interactive first-run wizard for the MCP entry and `install`.

## [0.7.3] - 2026-06-04

- Adds `http_anomaly` alerts for p95 latency or error rate jumping against a baseline.
- Adds a `continuation` block to `network_status` after a host restart.

## [0.7.2] - 2026-06-04

- Adds `report_issue` to file a `bug` or `ux` issue against this MCP.
- Adds `priorOccurrences` to `alerts_drain` and `alerts_peek`.

## [0.7.1] - 2026-06-04

- Adds crash telemetry in a hash-chained local audit log, with opt-out.
- Adds `audit verify` and `audit show` to check and print the log.

## [0.7.0] - 2026-06-04

- Adds `network_summarize`, one digest row per endpoint.
- Improves `network_get` by truncating JSON and HTML by structure.

## [0.6.3] - 2026-06-04

- Adds alert deduplication by signature with `occurrenceCount`.
- Changes `network_status.alerts` to show `pendingTotal` and `pendingEvents`.

## [0.6.2] - 2026-06-03

- Adds DTD auto-discovery at startup and `network_discover_dtd` to list live DTDs.
- Adds `knownApps` to `network_status` and auto-attach across every running DTD.
- Adds `install` for a native binary and `update` to re-run activation.
- Adds a daily update check and an `mcp` block with `updateAvailable`.
- Adds `autoAttachSuggestion` to `network_attach`.
- Changes auto-attach to evaluate running apps on its first tick.

## [0.6.1] - 2026-05-28

- Fixes auto-attach races, a failing tick stopping the watcher, and an unbounded URI set.
- Fixes a database that fails to open exiting with a stack trace.
- Fixes log stream errors killing the logging subsystem.
- Adds `--auto-attach-deny` to exclude apps even when the allowlist admits them.
- **Breaking:** Requires `--auto-attach` to take an allowlist (`--auto-attach=app1,app2`).

## [0.6.0] - 2026-05-28

- Adds multi-attach of several sessions, with `sessionId` or `appNameContains` scoping.
- Adds `network_detach` scoping by `sessionId`, `appNameContains` or `all:true`.
- Adds `--auto-attach` for apps that start after the server.
- Adds capture from every isolate of an app, with an `isolateId` filter.
- Adds `network_correlate` to pair a request with its webhook in another session.
- Changes `pendingAlerts` to count only the calling tool's session.
- **Breaking:** Drops `force:true` from `network_attach`; the same app cannot attach twice.
- **Breaking:** Scopes `alerts_clear` to one session instead of all sessions.

## [0.5.18] - 2026-05-24

- Adds a when-to-use line per tool in the README and a UX friction issue template.
- Improves eight tool descriptions to lead with when to use them.

## [0.5.17] - 2026-05-24

- Adds server instructions to file a bug report on bugs or confusing output.

## [0.5.16] - 2026-05-24

- Adds `FLUTTER_NETWORK_MCP_DATA_DIR` to set the data directory.
- Changes the macOS data directory to `~/Library/Application Support/flutter_network_mcp`.
- Fixes a fresh install crashing when the default data directory is unwritable.

## [0.5.15] - 2026-05-22

- Adds `pendingAlerts` to every successful tool reply when alerts are undrained.

## [0.5.14] - 2026-05-22

- Improves `docs/tools/` with 11 use-case folders.

## [0.5.13] - 2026-05-22

- Improves the README and `docs/README.md`, and adds a bug-report issue template.

## [0.5.12] - 2026-05-22

- Adds `summary`, `warnings` and `nextSteps` to `network_query` and the storage tools.

## [0.5.11] - 2026-05-22

- Adds `summary`, `warnings` and `nextSteps` to the six session tools.
- Fixes `session_delete` dry-run and `session_export` reporting every count as 0.

## [0.5.10] - 2026-05-22

- Adds summaries, `warnings` and `nextSteps` to the alert tools.
- **Breaking:** Requires `confirm:true` for `alerts_clear` with `drainedOnly:false`.

## [0.5.9] - 2026-05-22

- Adds `severeCount`, filters and warnings to `logs_tail`, and `clearedCount` to `logs_clear`.

## [0.5.8] - 2026-05-22

- Adds `summary`, `warnings` and `nextSteps` to the socket tools.

## [0.5.7] - 2026-05-22

- Adds `summary`, `warnings` and `nextSteps` to six network tools, with one error shape.
- Changes `network_diff` to omit unchanged diffs and reject `idA == idB`.
- Changes `network_detach` to report the rows captured in the session.

## [0.5.6] - 2026-05-22

- Adds `summary`, `nextSteps` and `warnings` to `network_get`.
- **Breaking:** Makes `events` in `network_get` opt-in with `includeEvents:true`.

## [0.5.5] - 2026-05-22

- Adds `summary`, `nextSteps` and `warnings` to `network_list`.

## [0.5.4] - 2026-05-22

- Adds `summary` and `warnings` to `network_attach`, which now suggests only enabled tools.
- Removes `httpProfilingEnabled`, `logStreamActive` and `capturesDbPath` from `network_attach`.

## [0.5.3] - 2026-05-22

- Adds `network_attach appNameContains` and `network_status attachIfOne`.
- **Breaking:** Errors `network_attach` when already attached; `force:true` restores the old way.

## [0.5.2] - 2026-05-22

- Fixes `dart pub global activate` failing with "Could not find bin/flutter_network_mcp.dart".

## [0.5.1] - 2026-05-22

- Improves `network_status` with a first-call DTD connect, `dbPath` and context-aware `nextSteps`.
- Changes `network_status` to split alert counts into `pendingCurrent` and `pendingTotal`.

## [0.5.0] - 2026-05-21

- Adds `session_delete`, `bodies_purge`, `db_stats`, `db_vacuum` and `alerts_clear`.
- Adds `redacted_headers` and `alert_patterns` for custom redaction and alert rules.
- Adds `FLUTTER_NETWORK_MCP_POLL_MS` and `FLUTTER_NETWORK_MCP_LOG_BUFFER` startup settings.
- Adds `headerTruncateBytes` to `network_get` and `maxLineLength` to `network_diff`.
- Improves `network_replay` and `network_query` with truncated bodies and size summaries.

## [0.4.0] - 2026-05-21

- Adds `network_search`, full-text search over URLs and bodies.
- Adds live alerts: `alerts_drain`, `alerts_peek` and `alerts_config`.
- Adds `--capabilities` and `--disable` to hide tools and capture paths.
- Adds `network_diff`, `network_replay`, `session_note` and `ignored_hosts`.
- Fixes `network_attach` hanging on a stale DTD.

## [0.3.0] - 2026-05-21

- Adds persistent captures in SQLite (`captures.db`) with HTTP bodies, sockets and logs.
- Adds `session_list`, `session_open`, `session_close` and `session_export`.
- Adds `network_query` for read-only `SELECT` queries.

## [0.2.0] - 2026-05-21

- Adds `network_list` cursors and filters, and `network_body` byte-range paging.
- Adds `socket_list`, `socket_get` and `socket_clear`.
- Adds log capture with `logs_tail` and `logs_clear`.

## [0.1.0] - 2026-05-21

- Adds a stdio MCP server with `network_status`, `network_attach`, `network_list` and `network_get`.
