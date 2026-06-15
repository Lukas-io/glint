---
tool: attach
description: Connect glint to a running Flutter app's VM service and bind a device target. Required before any other tool.
when_to_use: First call of every session. Always.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached and the user just wants to read the screen — `get_scene` works against the existing attachment.
- The user gave you only an app name with no VM service URI — they need to launch a debug Flutter app and copy the `ws://…` from the console first. Tell them what they need.
- The app is a release / profile build — the VM service is stripped, attach will fail with a clear error from the VM library.
- You suspect the previous VM URI is stale — restart the Flutter app and use the new URI; reattaching to a dead URI loses 5s to a timeout.
- You're trying to "discover what apps exist" — that's a planned `auto_attach` story (not in v0). For now the user is the discovery channel.

## Use this when

- The user opens a new agent session and wants to drive a running app.
- The user has just restarted the app and the previous attachment is dead. `attach` is idempotent — re-attaching replaces the previous connection.
- You need to switch between two devices in the same session. Call `attach` again with the new `vmUri` + `device`.

## How it works

1. Parses `vmUri` as a WebSocket URL.
2. Builds the `DeviceTarget` (`AndroidDevice` or `IosSimulator`) based on `platform`. For iOS, runs a one-shot viewport probe via the inspector to read the logical W/H and DPR — saves the agent a separate round-trip later.
3. If a session was already attached, detaches it first (idempotent re-attach).
4. Opens the VM service, picks the Flutter isolate, subscribes to Stderr / Stdout / Logging streams so the app-log buffer fills in the background.
5. Wires the scene reader, inspector client, coordinate resolver, interactor, semanticizer, settle detector — every other tool reads through these.

## Args

- `vmUri` (string, required) — WebSocket VM service URI, e.g. `ws://127.0.0.1:1234/abc=/ws`. From the Flutter app's launch console.
- `platform` (string, required) — `ios` or `android`.
- `device` (string, required) — iOS simulator UDID, or Android emulator/device serial (`adb devices`).
- `iosBridgePath` (string, optional, iOS only) — path to the compiled `glint-iossim` Swift binary. Defaults to `native/ios_sim_bridge/.build/debug/glint-iossim` (the repo-relative build).
- `adbPath` (string, optional, Android only) — `adb` executable path. Defaults to `adb` (on PATH).

## Returns

Success:
```json
{
  "summary": "attached to ios device <UDID> at ws://…",
  "data": {
    "platform": "ios",
    "device": "<UDID>",
    "logicalWidth": 390.0,
    "logicalHeight": 844.0,
    "devicePixelRatio": 3.0
  },
  "nextSteps": [
    "call `get_scene` to read the current screen",
    "use `tap` / `swipe` / `type` / `hardware_button` to drive the app"
  ]
}
```

The `logicalWidth` / `logicalHeight` / `devicePixelRatio` fields only appear for iOS (the probe runs there). Android backends derive their viewport at action time.

Error (`unknown platform`):
```json
{
  "isError": true,
  "data": {"errorKind": "invalidArgument"},
  "nextSteps": ["use one of: ios, android"]
}
```

Error (`probe failed`) — surfaces as `internal` with the inspector-eval detail. Usually means the app is in a state with no addressable widget (white screen, splash). Wait 1–2s and retry.

## Pairs well with

- `get_scene` — almost always the next call.
- `session` — when you want to inspect attach state before deciding to re-attach.
- `report_issue` — when the probe fails on a real-looking app, file a `bug`.

## Example

```
> attach  vmUri:"ws://127.0.0.1:50123/abc/ws"  platform:"ios"  device:"D8A5E2..."
< {summary:"attached to ios device D8A5E2…", logicalWidth:390, logicalHeight:844, dpr:3}
> get_scene
< (the tree)
```
