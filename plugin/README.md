# glint for Claude Code

This plugin adds two MCP servers to Claude Code:

- **glint** reads a running Flutter app's screen and drives it like a user, on iOS simulators, Android emulators and iPhones. Every action reports what changed.
- **glint network** reads the same app's HTTP, WebSocket and log traffic.

## Install

```
/plugin marketplace add Lukas-io/glint
/plugin install glint@glint
```

From a shell, the same is `claude plugin marketplace add Lukas-io/glint`, then `claude plugin install glint@glint`.

You need the Dart SDK, which comes with Flutter, on your `PATH`.

## First start

The servers come from pub.dev (`glint_mcp` and `glint_network`). The first time each one starts, the plugin installs it with `dart pub global activate`, which takes about 20 seconds. If Claude Code reports a server as failed during that first install, run `/mcp` to reconnect; it starts at once from then on.

To skip the wait, install them beforehand:

```bash
dart pub global activate glint_mcp
dart pub global activate glint_network
```

`glint_network update` and `dart pub global activate glint_mcp` move each server to its latest release.

## Already set up glint by hand?

If you added glint with `claude mcp add`, remove that entry (`claude mcp remove glint`, `claude mcp remove glint-network`), so the agent does not see every tool twice.

## Use it

Run your app in debug mode (`flutter run`), then ask Claude to attach and work with it, for example *"Attach to my app, sign up with a test email and tell me what the next screen says"*, or *"Why did the last login request fail?"*.

Tools, platforms and limits are in the [glint README](https://github.com/Lukas-io/glint#readme).
