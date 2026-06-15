# Crash + usage telemetry

> Status: **shipped.** Crash payloads + audit log + opt-out are wired into the running `bin/glint.dart`. The collector is shared with `flutter_network_mcp` (one Cloudflare Worker + D1 disambiguates by `version` field), so glint payloads land in the same table.

## The trust pact

Telemetry is **on by default**, with an opt-out env var. In exchange, the MCP writes a **tamper-evident local audit log** of every byte it sends to the collector — same payload, same encoding, hash-chained so any silent edit is detectable. The user can run `glint telemetry op:"audit_verify"` at any time to walk the chain and prove nothing was sent without their knowledge.

The trade-off: more signal (so bugs surface in days instead of months when somebody bothers to file an issue), in exchange for full transparency to the user about what we know.

## Motivation

Most MCP crashes evaporate silently. The user sees a Dart trace, shrugs, moves on. The maintainer never finds out until somebody happens to file a GitHub issue weeks later — usually for the third or fourth person hitting the same bug, after the first three gave up.

Default-on telemetry closes that gap. The `runZonedGuarded` around `main()` catches every uncaught error; with telemetry wired in, those crashes become signal we can act on within a day.

## Constraints

1. **Default ON.** Telemetry runs unless the user sets `GLINT_NO_TELEMETRY=true`. No opt-in dance.
2. **Tamper-evident local audit log.** Every payload that goes to the wire ALSO goes to `<dataDir>/telemetry-audit.log` as a hash-chained append-only record. Both crash payloads and usage rollups go into the same chain, tagged via `kind`. The user can audit + verify both via the same `audit_show` / `audit_verify` ops.
3. **No PII, no app data, no source paths.** The payload contains only safe identifiers (see schema below). Never: usernames, hostnames, target project paths, captured app state, glintIds, scene text, env-var contents.
4. **Best-effort, non-blocking.** Network failure must not crash the MCP or block shutdown. Single attempt with a 3s total deadline. The audit log write happens BEFORE the network attempt, so even if the wire send fails the user still sees what we tried to send.
5. **One endpoint, version-pinned.** Hardcoded for now; baked into `lib/src/observability/telemetry/constants.dart`.

## The opt-out

```bash
export GLINT_NO_TELEMETRY=true     # everything: crash + usage rollups
export GLINT_NO_USAGE=true         # usage rollups only; crashes still report
```

Setting `GLINT_NO_TELEMETRY=true` short-circuits the whole path — no network attempt, no audit log write, no payload built. The `runZonedGuarded` handler still catches uncaught errors and logs them to stderr — it just doesn't report.

For regulated environments (SOC 2, healthcare, defense, customer machines with strict outbound policy) this is the path. Set the env var in your shell rc, your CI runner config, your container baseline.

## Local audit log

Location: `<dataDir>/telemetry-audit.log` — same data dir as the usage watermark. Default: `~/.glint/telemetry-audit.log`. Override: `GLINT_DATA_DIR=<path>`.

Format — one JSON-ish line per report:

```
<ts>|<prev_hash>|<payload_b64>|<this_hash>
```

- `ts` — ISO-8601 UTC timestamp when the report was written.
- `prev_hash` — SHA-256 hex of the previous line's `this_hash`. First line uses 64 zeros.
- `payload_b64` — base64 of the EXACT JSON bytes that were sent (or would have been). Byte-for-byte parity with the POST body.
- `this_hash` — SHA-256 hex of `<ts>|<prev_hash>|<payload_b64>`. Forms the chain.

### Tamper-evidence (not tamper-prevention)

The audit log lives on the user's disk; they own it; they CAN edit it. The chain doesn't prevent that — it makes it visible. Any line edited in place breaks the local hash check. Any line removed breaks the next line's `prev_hash`. The user can prove the log is intact OR find the exact point where it diverges.

Same model as `git log`: the chain isn't enforced by the filesystem, it's enforced by the hashes that anyone with the file can verify.

### Verification (via the MCP tool)

```
> telemetry op:"audit_verify"
< {intact: true, totalEntries: 47, firstTs: "...", lastTs: "..."}
```

On a break:

```
< {intact: false, brokenAtIndex: 23, brokenReason: "prev_hash mismatch"}
```

### Inspection (via the MCP tool)

```
> telemetry op:"audit_show"  limit:20
< {totalEntries: 47, shown: 20, entries: [{ts, thisHash, prevHash, payload}, ...]}
```

## Crash payload schema

```jsonc
{
  "kind": "crash",
  "version": "glint/0.0.1",                       // disambiguates from flutter_network_mcp
  "commit": "4aa550c…",                           // 12-char hex; null when SHA unknown
  "isAot": false,                                 // true under `glint install`
  "os": "macos 14.6",                             // platform.os + truncated version
  "dart": "3.5.0",                                // platform.version, version-only
  "errorClass": "StateError",                     // error.runtimeType.toString()
  "errorMessage": "Inspector eval failed.",       // truncated 200 chars
  "stackHead": ["#0 frame...", "#1 frame..."],   // 8 frames, paths redacted
  "signature": "a3f7c8d219b4",                   // sha256(errorClass + top-3)[:12]; dedupe key
  "machineHash": "f1a823bc91…",                  // HMAC(dataDir, salt)[:24]; dedupe key
  "reportedAt": "2026-06-15T12:34:56Z"
}
```

What's **NOT** in the payload (enforced by the redactor, audited by the local log):

- `$HOME`, `cwd`, target Flutter project path, any path under `/Users/<name>/…` or `C:\Users\<name>\…`
- The target app's `vmServiceUri`, simulator UDID, device serial
- Any glintId from the running app, any `textPreview`, any scene content
- Env var contents (only `GLINT_NO_TELEMETRY` presence is read, never logged)

## Usage rollup schema

Sent once per UTC day (when telemetry is on). Aggregates the per-call events the recorder has accumulated since the last ship:

```jsonc
{
  "kind": "usage_rollup",
  "version": "glint/0.0.1",
  "os": "macos 14.6",
  "dart": "3.5.0",
  "machineHash": "f1a823bc91…",
  "window": {"firstEventMs": ..., "lastEventMs": ..., "toEventId": 1240},
  "totalEvents": 47,
  "totalTurns": 8,
  "tools": [
    {"tool": "get_scene", "count": 12, "ok": 12, "error": 0, "empty": 0, "p50Ms": 38, "p95Ms": 110, "avgResultBytes": 412}
  ],
  "transitions": [
    {"from": "get_scene", "to": "tap", "count": 9}
  ],
  "reportedAt": "2026-06-15T12:34:56Z"
}
```

What's **NOT** in the rollup:

- Per-call rows (only aggregates leave the machine).
- Arg values (only sorted arg *keys* are recorded, and only used to derive per-tool stats — the keys don't ship either).
- glintIds, app names, paths, error messages.

## Path redaction (the hardest part)

Stack traces contain `package:` paths (safe, package-relative) AND raw filesystem paths (NOT safe, contain `$HOME`). The redactor walks each frame and replaces:

- `/Users/<name>/StudioProjects/<project>/…` → `<project:<name>>/…`
- `/Users/<name>/…` → `<home>/…`
- `C:\Users\<name>\<project>\…` → `<project:<name>>\…` (Windows)

Regex-based, idempotent. Source: `lib/src/observability/telemetry/path_redactor.dart`. Same redactor is applied to issue bodies in `report_issue`.

## Signature (the magic field)

`signature = sha256(errorClass + top-3-frames-redacted)[:12]`

Identical bugs collapse into one row group at the collector. `SELECT signature, COUNT(*), MAX(received_at) FROM crashes GROUP BY signature ORDER BY 2 DESC` answers "what's the most common crash right now."

Stable across machines: the only inputs are class name + redacted package-relative paths + line numbers. Different patch versions can change line numbers; we accept that as the "what changed" signal.

## Where the collector lives

`https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry` — a Cloudflare Worker + D1 SQLite. Routes by `kind` (`crash` vs `usage_rollup`), disambiguates products by `version` (`glint/…` vs `flutter_network_mcp/…`). Free-tier handles 100K writes/day.

The Worker source isn't in this repo (lives in `flutter_network_mcp/collector/`); glint just POSTs to it.

## What this doesn't do

- **Per-user identity.** `machineHash` is per-`dataDir`, not per-user. Two installs on the same machine with different `GLINT_DATA_DIR` values count as two machines. That's fine.
- **Encrypted-at-rest collector storage.** Standard TLS in transit is sufficient — anonymized payloads with no user-identifying content don't need at-rest encryption beyond what D1 provides.
- **Performance profiling.** Per-tool latency p50/p95 is in the usage rollup; finer-grained tracing isn't shipped.
