# glint

**Let an AI agent use your Flutter app the way a person would.**

You tell an agent what you want done — "sign in as test@example.com, find the order from yesterday, and cancel it" — and it taps, scrolls, and types its way through your app on a simulator until it's done. The app doesn't need to be modified. No package to add. No init code. Glint reads your running app from the outside and drives it through native input.

> **Status:** v1 in development. Not ready to use yet. Source-of-truth is [`source-of-truth.md`](./source-of-truth.md).

---

## In plain language

Today, if you want an agent to drive a Flutter app, your options are bad:

- **Screenshot + vision model.** Slow, expensive, and the agent is guessing where to tap from pixels. Misses anything that isn't visually obvious.
- **Add a test package to your app.** Now you're shipping testing code in your real codebase, and you can't run it on the same build your users use.
- **Build it yourself.** Months of VM-service spelunking and platform input gluework.

Glint is the third option, done for you, and built so the agent runs as fast as a person — sometimes faster.

It works by reading the **live state of your running app** (via the Dart VM service in debug mode) and sending **real OS-level taps** to the simulator. So the agent always knows what's actually on screen, what's actually tappable, and where it is in your navigation stack. And because we read what *could* appear on the next screen alongside what *is* on the current screen, the agent can declare its next move ahead of time — and we fire it the instant the screen is ready, with no waiting.

## What it does (today's scope)

- **Drives any Flutter app** on the iOS Simulator or Android Emulator. No modification to the app required.
- **Acts**: tap, long press, double tap, swipe, drag, scroll, type text, key events, and hardware buttons (home, lock, volume, back).
- **Sees**: every element on screen with two truths — `painted` (is a human looking at it?) and `hittable` (would a tap actually land on it?). These diverge in real apps.
- **Orients**: knows the navigation stack, including dialogs and bottom sheets, not just routes.
- **Describes**: gives the agent a compact plain-language scene, not a coordinate dump.
- **Scrolls to find**: virtualized lists only build what's near the viewport — glint will scroll to bring an off-screen item into the tree as a first-class action.

## What makes it fast

Most agent loops look like: act, wait for screen to settle, model wakes up, reads, decides, acts again. Every "wake up" is a full LLM round trip. Glint kills this with **armed intent**:

1. The agent reads the screen *and* peeks at the widget tree (what's about to appear).
2. It declares its next move ahead of time — even against a target that isn't on screen yet.
3. Glint holds the intent. The moment the target appears *and* passes a real hit test, the action fires automatically.
4. If the prediction was wrong, a structured "catch" wakes the agent with the actual state.

The agent only spends thinking time on (a) deciding what's next and (b) handling catches. When the prediction holds, the flow runs at server speed.

## What's deliberately not in scope (v1)

- **Not a testing tool.** No assertions, no test runner. We're building task execution, not verification. Recap (record-and-replay with metrics) is on the roadmap.
- **No animation handling.** v1 acts on settled states.
- **No multi-touch on Android.** Pinch/rotate need raw `sendevent` and are deferred.
- **No real devices.** Simulators and emulators only, debug mode only.
- **No CLI for humans.** Agent-first; a human-driven interface is future work.

Full scope and non-goals: see [`source-of-truth.md`](./source-of-truth.md) §4–§5.

## Technical sketch

Four modules behind an MCP server (stdio transport for v1):

| Module | Job | How |
|---|---|---|
| **A — Interaction** *(hands)* | Native input on the simulator | Swift bridge against `CoreSimulator.framework` for iOS; `adb shell input` for Android |
| **B — Perception** *(eyes)* | Read the live render tree | Dart VM service. Surfaces `painted` and `hittable` separately. Coordinates resolved lazily — never cached. |
| **C — Semantic layer** *(understanding)* | Plain-language scene the agent reads | Derived from render primitives, zero-config |
| **D — Instruction layer** *(grammar)* | Tool grammar + worked examples + gotchas | Treated as first-class; an MCP tool is only as good as the instructions shipped with it |

Built in Dart on top of `package:dart_mcp`, `package:vm_service`, and `package:dtd` — porting hardened patterns from [flutter_network_mcp](https://github.com/Lukas-io/flutter_network_mcp) where they apply (DTD discovery, structured response shapes, AOT install flow).

Supported Flutter: latest stable + one before (currently 3.27+). Floor moves up with new stable releases.

## Roadmap

v1 focuses on **discovery-mode task execution** — making the first run through a flow fast and accurate. Beyond v1:

- **Persona-driven user testing.** Hand the agent a user persona; have it use the app the way that persona would, including the wandering and naive behaviour. Built as a separate product on top of glint's core.
- **Recap (record-and-replay).** For known flows. Replay has no per-step thinking — this is how you beat a human on repetitive tasks.
- **Custom widget enrichment.** Out-of-band map of semantic descriptions for custom widgets. Never an edit to the app.
- **Animation + transform awareness.** Correct coordinate resolution inside animating subtrees.
- **Multi-touch on Android.** Pinch and rotate via `sendevent`.
- **Real device support.** Constrained by native input injection paths.
- **Non-MCP interface.** CLI / UI for humans driving the same capabilities directly.

Full roadmap: [`source-of-truth.md`](./source-of-truth.md) §11.

## Install / use

Not ready yet. v1 is in development. Check back, or read the [source-of-truth](./source-of-truth.md) to follow along.

## License

[PolyForm Noncommercial 1.0.0](./LICENSE).

You can use, modify, study, and contribute to glint for any noncommercial purpose — personal projects, research, education, internal evaluation, non-profit work. **Selling glint, hosting it as a paid service, or any commercial use requires written authorization from the author.** Reach out if that's what you want; commercial licensing is on the table.

## Contributing

Pre-v1, so contribution shape is still settling. If you're interested, read [`source-of-truth.md`](./source-of-truth.md) first — every architectural decision lives there.
