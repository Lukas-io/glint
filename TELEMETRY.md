# Telemetry

glint sends nothing anywhere unless you turn sharing on.

## What stays on your machine

Every tool call adds one line to `~/.glint/usage-events.jsonl`: the time, the tool name, the outcome (ok, empty or error), the names of the arguments used (never their values), how long the call took, the size of the reply and, on failure, the error kind. `telemetry op:report` summarizes it for you. Set `GLINT_NO_USAGE=true` or `GLINT_NO_TELEMETRY=true` to stop recording it.

## What is sent if you opt in

Set `GLINT_TELEMETRY=on` to share an anonymous daily summary. Once a day at startup, and when glint exits, it posts one rollup to `https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry` containing:

- glint's version, the operating system name and version, and the Dart SDK version;
- a random install id, created once in `~/.glint/install-id` and not derived from your username, paths or hardware;
- the time window and event-id range the summary covers;
- per tool: call counts, ok/empty/error counts and rates, latency statistics, average reply size, estimated tokens, and error kinds;
- which tool followed which (tool names and outcomes only), and how often an error was recovered on the next call.

Never sent: argument values, typed text, scene contents, glintIds, app or project names, file paths, URLs, screenshots, or any single event.

## Checking what was sent

Every summary is written to the hash-chained `~/.glint/telemetry-audit.log` before any network attempt. `telemetry op:dryRun` shows the next summary without sending it, `telemetry op:audit_show` lists past ones, and `telemetry op:audit_verify` checks that the log was not edited.

## Switches

| Variable | Effect |
| --- | --- |
| `GLINT_TELEMETRY=on` | Share the anonymous summary. Off unless set. |
| `DO_NOT_TRACK=1` | Never share, even with `GLINT_TELEMETRY=on`. |
| `GLINT_NO_TELEMETRY=true` | Never share and stop local recording. |
| `GLINT_NO_USAGE=true` | Same as above for usage stats. |
| `GLINT_NO_UPDATE_CHECK=true` | Don't ask pub.dev for glint's latest version. |

An agent cannot turn sharing on: the switches are environment variables only.

## Update check

Once a day at startup, glint asks pub.dev for the latest `glint_mcp` version (`GET https://pub.dev/api/packages/glint_mcp`) and caches the answer in `~/.glint/update-check.json`. The request carries nothing about you or your apps. When a newer version is out, `attach` says so once per session so the agent can tell you. `GLINT_NO_UPDATE_CHECK=true` turns the check off.
