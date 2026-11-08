# Changelog

All notable changes to glint_core are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, where before 1.0 a minor bump may break things.

## [Unreleased]

## [0.2.0] - 2026-11-08

### Added

- `ProcessRegistry.livePids` returns the pids of the helpers this process holds, with no `ps`.
- `IdentityRedactor`, `RedactionCounts`, `isPublicHost` and `projectIdentityNames`; `redactForSharing` takes `appNames`, `deviceNames`, `hosts` and `counts` and replaces them with `<app>`, `<device>` and `<host>`.
- `ProcessRegistry`, `killTree`, `ProcessTable` and `watchParentDeath` track the helper processes glint starts, reap stale ones at startup and kill a whole tree.

## [0.1.3] - 2026-10-18

### Added

- `latestPubVersion`, `cachedPubVersion` and `isNewerVersion` look up a package's latest pub.dev version, at most once a day, for update notices.

## [0.1.2] - 2026-10-15

### Changed

- An example, analysis options and `dart format` so the package scores fully on pub.dev.

## [0.1.1] - 2026-09-27

### Added

- `editDistance`, the Levenshtein distance both packages' suggestions use.
- `connectVmService`, `vmServiceWsUri`, `canonicalVmServiceUri` and `instanceText` connect to the Dart VM and read full strings.
- `fileWithGh`, `issueLabels`, `composeIssueDeepLink`, `capDeepLinkBody`, `saveFullIssueBody`, `existingLabels`, `selectApplicableLabels` and `isMissingLabelError` file agent-reported issues.
- `summarizeUsage`, `buildUsagePayload`, `UsageShipper`, `UsageEventSource`, `TurnTracker`, `usageOutcome`, `usageArgKeys` and `estimateTokens` roll up and ship usage.

## [0.1.0] - 2026-09-26

### Added

- `redactPath`, `redactStackHead`, `redactSecrets` and `redactForSharing`, moved from glint_mcp and glint_network; secret masking also catches `access_token=` and `refresh_token=`.
- `AuditLog`, the hash-chained telemetry audit log both packages write.
- `installId`, `osDescriptor`, `dartVersion`, `truthyEnv`, `postToCollector` and `TelemetrySwitches` for opt-in telemetry.

### Fixed

- `AuditLog.append` no longer forks the chain or loses entries when servers append at the same moment; `verify` counts old forks in `forks` instead of flagging tampering.
