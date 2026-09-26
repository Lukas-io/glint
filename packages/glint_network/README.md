# glint_network

The network toolset of [glint](https://github.com/Lukas-io/glint). Formerly flutter_network_mcp.

Give AI coding agents visibility into your running Flutter app's network traffic.

The [official Dart and Flutter MCP server](https://docs.flutter.dev/ai/mcp-server) is good at code and app introspection: it can fetch runtime errors, read the widget tree, hot reload, run tests, and search pub.dev. What it can't do is show an agent the network. There's no tool for HTTP requests, responses, sockets, or logged traffic. So when you're debugging an API bug with an agent, you're back to alt-tabbing to DevTools, copying the request, and pasting it into the chat by hand.

This server fills that gap. It connects to a running Flutter or Dart app through the Dart Tooling Daemon and exposes the app's network traffic, sockets, and logs as tools the agent calls directly. Captures persist to a local SQLite database so they survive across sessions, and the server flags HTTP errors, slow requests, and Flutter exceptions on its own so the agent can pick them up without being asked.

## Why

Agents debug better with real runtime data than with pasted snippets. Instead of you shuttling requests back and forth, the agent reads the live network tab itself, searches every body you've captured, compares today's behavior against a previous session, and opens an investigation when something breaks.

Good for:

- Debugging API issues with an agent without copy-pasting requests around.
- Comparing app behavior across sessions, for example whether the auth header changed since Tuesday.
- Generating a HAR file from a capture session to hand a coworker.
- Finding the one request containing a specific error across weeks of history.

Not for: production observability, traffic outside `dart:io` HTTP, or release builds, where the VM service is stripped.

## Limits today

- **Only traffic that goes through `dart:io` is captured.** Native SDKs (analytics, crash reporting, ads, maps) and gRPC or HTTP/2 stacks are invisible; gRPC shows up only as socket byte counts. Native HTTP clients such as `cupertino_http` and `cronet_http` are not verified yet.
- **WebSockets are metadata only**: connections, message direction, type and size, never contents. They need an app built with Dart 3.13 or newer.
- **Flutter web is not supported.**
- **One database per machine**, shared by every project you capture. Bodies are stored as captured; secret headers are stored as `<redacted>`.
- **macOS and Linux hosts.** Windows install is not working yet.

## Requirements

- Dart SDK or Flutter installed, with `~/.pub-cache/bin` on your `$PATH`.
- A Flutter or Dart app running in debug mode, so the VM service is available.
- An MCP-capable agent host such as Claude Code or Cursor.

## Install

```bash
dart pub global activate -s git https://github.com/Lukas-io/glint.git --git-path packages/glint_network
glint_network install
```

The `install` step compiles a native binary so the server starts in under 100ms instead of recompiling a JIT snapshot on every launch. Skipping it can cause the agent host to intermittently mark the server as failed on first connect.

## Moving from flutter_network_mcp

> **The flutter_network_mcp names stop working on 26 December 2026.** That covers the `flutter_network_mcp` command, the `FLUTTER_NETWORK_MCP_*` variables, and updates from the old repository. Until then everything keeps working, and the server tells your agent what is left to change.

1. Run `flutter_network_mcp update`. It moves your install to this repository; your captures, settings and native build carry over.
2. In your MCP config, rename the `flutter-network` entry to `glint-network` and set its `command` to `glint_network`.
3. Rename any `FLUTTER_NETWORK_MCP_*` variables to `GLINT_NETWORK_*`.
4. Restart your agent host. `network_status` stops showing the notice once nothing old is left.

## Configure

Add the server to your project's `.mcp.json`, or `~/.claude.json` for machine-wide:

```json
{
  "mcpServers": {
    "glint-network": {
      "type": "stdio",
      "command": "glint_network"
    }
  }
}
```

The server auto-discovers a running app's Tooling Daemon on startup, so no connection URI is needed in most setups. To target a specific daemon, pass `--dtd-uri "ws://127.0.0.1:<port>/<token>="`.

## Quickstart

Once configured, ask your agent to work with the running app:

```
You:    Attach to my app and tell me what's breaking.
Agent:  network_status -> network_attach -> alerts_drain
        3 alerts, 1 critical (Null check on null at home_screen:42),
        2 errors (503 on /v1/login)

You:    Find the login request that failed.
Agent:  network_search query:"invalid_token"
        POST /v1/login, 500, snippet "invalid_token"

You:    Show me the full response.
Agent:  network_get, returns headers and body
```

Captures are saved automatically. The next day, `session_list` shows what you captured and `session_open` reopens it.

## What it does

Live capture. HTTP requests (method, URL, headers, status, bodies), `dart:io` sockets, WebSocket connections and their message timeline (type and size, not contents; apps built with Dart 3.13+), and app logs, streamed as they happen. Nothing is added to the app.

Persistence. Every attach opens a SQLite session. Reopen past sessions, run ad-hoc SQL, or export to HAR 1.2 for sharing.

Alerts. Detection rules run on every request and log line, flagging 4xx and 5xx responses, `dart:io` errors, slow requests, and Flutter exceptions. The agent drains the queue at the start of an investigation.

Full-text search. Ranked, highlighted search across every captured URL and body.

Multi-app. Attach to several running apps at once, for example a customer app and a driver app, and correlate requests across them by a shared id.

Capture control. Host and path glob filters, an opt-in allowlist, and an ephemeral no-persist mode for sessions you don't want written to disk. Secret headers (authorization, cookies, API keys, plus any you add) are redacted before they are stored; set `GLINT_NETWORK_STORE_SECRETS=true` to keep them for local replay. Exports and SQL output also mask tokens, passwords and keys found in bodies.

The server exposes 50 tools across HTTP, sockets, WebSockets, logs, alerts, search, sessions, SQL, and admin categories. Every tool returns a consistent shape with a summary, suggested next steps, and any warnings, so the agent can act without parsing prose.

## Documentation

- [Tool reference](docs/tools): every tool has its own page, including when not to use it.
- [Configuration and environment variables](docs/configuration.md): capability gating, auto-attach, data directory, database size caps.
- [Telemetry and privacy](docs/telemetry.md): what is collected, what is never collected, the local audit log, and how to opt out.

## Contributing

Reports help. If you use an MCP-capable agent, say "file a bug for this" or "file a UX friction report" and the agent drafts it for you to approve; it lands in the [glint issue tracker](https://github.com/Lukas-io/glint/issues) with the `network` label. How changes, checks and releases work is in [MAINTAINING.md](../../MAINTAINING.md).

Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Local development

```bash
git clone https://github.com/Lukas-io/glint.git
cd glint && dart pub get
cd packages/glint_network
dart analyze
dart run bin/glint_network.dart --dtd-uri 'ws://...' --data-dir /tmp/captures
```

Built with `package:dart_mcp`, `package:dtd`, `package:vm_service`, and `package:sqlite3`.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
