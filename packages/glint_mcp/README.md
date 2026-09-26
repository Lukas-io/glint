# glint_mcp

The glint MCP server. It lets an AI agent read a running Flutter app's screen and drive it on an iOS Simulator or Android emulator, with nothing added to the app.

Setup, the tool list and current limits are in the [repository README](https://github.com/Lukas-io/glint#readme). Changes are listed in [CHANGELOG.md](./CHANGELOG.md).

## Run it from a checkout

```bash
dart pub get
dart run bin/glint.dart --help
```

On iOS the server drives the simulator through the `glint-iossim` bridge in `native/ios_sim_bridge`. Build it with `swift build -c release`, or let glint download the prebuilt one on the first iOS attach.
