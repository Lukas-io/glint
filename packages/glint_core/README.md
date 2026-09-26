# glint_core

Code shared by the [glint](https://github.com/Lukas-io/glint) packages, so each rule lives in one place:

- **Redaction** for anything that leaves the machine: home and project paths, stack traces, and secrets (JWTs, bearer tokens, long hex keys, `password=`-style values).
- **The telemetry audit log**: a hash-chained file recording every payload before any network attempt, so users can check exactly what was sent.
- **Telemetry identity and consent**: the random install id, host descriptors, the collector POST, and the opt-in switches, read under each package's own env var prefix.

Its API is internal to this repository until it is published. See [MAINTAINING.md](../../MAINTAINING.md#shared-code).
