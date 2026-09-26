# Changelog

All notable changes to glint_core are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, where before 1.0 a minor bump may break things.

## [Unreleased]

### Added

- Redaction: `redactPath`, `redactStackHead`, `redactSecrets` and `redactForSharing`, moved from glint_mcp and glint_network. Secret masking uses the stricter of the two copies, which also catches `access_token=` and `refresh_token=` values.
- `AuditLog`: the hash-chained telemetry audit log both packages already wrote in the same format.
- Telemetry basics: `installId`, `osDescriptor`, `dartVersion`, `truthyEnv`, `postToCollector`, and `TelemetrySwitches` for the opt-in variables under a package's prefix.
