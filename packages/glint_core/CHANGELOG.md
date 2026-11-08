# Changelog

Versions follow semver; before 1.0 a minor bump may break things.

## [Unreleased]

## [0.2.0] - 2026-11-08

- Adds `ProcessRegistry`, `killTree`, `ProcessTable` and `watchParentDeath` for helper processes.
- Adds `ProcessRegistry.livePids` to list live helper pids without `ps`.
- Adds `IdentityRedactor`, `RedactionCounts`, `isPublicHost` and `projectIdentityNames`.
- Adds `appNames`, `deviceNames`, `hosts` and `counts` to `redactForSharing`.

## [0.1.3] - 2026-10-18

- Adds `latestPubVersion`, `cachedPubVersion` and `isNewerVersion` for update notices.

## [0.1.2] - 2026-10-15

- Improves pub.dev scoring with an example, analysis options and formatting.

## [0.1.1] - 2026-09-27

- Adds `editDistance`, the Levenshtein distance behind suggestions.
- Adds `connectVmService`, `vmServiceWsUri`, `canonicalVmServiceUri` and `instanceText`.
- Adds `fileWithGh`, `composeIssueDeepLink` and related helpers for agent-reported issues.
- Adds `summarizeUsage`, `UsageShipper`, `TurnTracker` and related helpers for usage rollups.

## [0.1.0] - 2026-09-26

- Adds `redactPath`, `redactStackHead`, `redactSecrets` and `redactForSharing`.
- Adds `AuditLog`, the hash-chained telemetry audit log.
- Adds `installId`, `postToCollector` and `TelemetrySwitches` for opt-in telemetry.
- Fixes `AuditLog.append` forking the chain when servers append at the same moment.
