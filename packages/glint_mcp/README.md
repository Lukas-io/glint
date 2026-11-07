# glint_mcp

The glint MCP server. It lets an AI agent read a running Flutter app's screen and drive it on an iOS Simulator, an Android emulator or an iPhone, with nothing added to the app.

Setup, the tool list and current limits are in the [repository README](https://github.com/Lukas-io/glint#readme). Changes are listed in [CHANGELOG.md](./CHANGELOG.md).

## Install

```bash
dart pub global activate glint_mcp
claude mcp add glint -- glint
```

## Run it from a checkout

```bash
dart pub get
dart run bin/glint.dart --help
```

On iOS the server drives the simulator through the `glint-iossim` bridge in `native/ios_sim_bridge`. Build it with `swift build -c release`, or let glint download the prebuilt one on the first iOS attach.

## Handing a step to a person with `watch`

Use `watch` whenever someone else must act before you can continue: a person enters a PIN, password or 2FA code, signs in, or confirms a real-money or destructive step, or a teammate or backend changes something the app reacts to minutes later. `watch` registers conditions, returns at once, and wakes the agent when one matches. Without it the agent ends its turn with "tell me when you're done" and waits.

`wait_for` is for what the agent itself just caused and blocks one call for up to 60 s. `watch` is for a person or a backend, and lasts up to 6 h (`timeoutMs`, default 30 min).

Example:

1. Register it before asking: `watch conditions:[{text:"Welcome back"},{text:"Wrong PIN"}] label:"human signs in"`. The reply carries the events file and a ready `tail -n0 -F ~/.glint/watch/<pid>.jsonl` line.
2. Run that `tail` line as a background shell monitor (the host does not show server notifications to an idle model).
3. Ask the person to sign in, and end the turn. Do not ask them to reply.
4. When the monitor wakes the agent, read the event (`kind` is `match` or `ended`, with `condition`, `matched` and `route`), run `get_scene`, and carry on.

Picking conditions:

- Watch for the screen after the person's action, not the action itself.
- Add a second condition for the failure path (an error text or sheet), so a wrong PIN does not look like silence. Any one condition firing ends a `once` watch.
- Use `{log:"<regex>"}` when the screen does not change. Other conditions are `{glintId, state:"appears"|"disappears"}`, `{route:"/home"}` (empty means any change) and `{overlay:"appears"|"dismisses"}`.

A watch that nothing matches ends with an `ended` event (`reason` `timeout`) after `timeoutMs`; it also ends on cancel or detach. Drop one early with `watch op:cancel id:"w1"` (or `all:true`), and see what is active with `op:list`.

If the host cannot wake an agent from a tailed file, poll instead: `watch op:events sinceSeq:<n>` returns the events after that seq and the next `sinceSeq` to use.

Device mode has no Flutter tree or logs to watch, so `watch` needs the Flutter debug app attached.
