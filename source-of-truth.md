# Source of Truth

Project name: **glint**.

This is the foundational document for the project. It defines who we are building for, what we are trying to achieve, what is in scope, what is intentionally out of scope, and the principles and modules that everything else hangs off. It is a living document. Every section is meant to be tracked and updated as milestones land. When a decision changes, it changes here first.

---

## 1. Who we are building for

We are building for AI agents.

The agent acts on behalf of a user. The user gives the agent a task in natural language, and the agent carries it out inside a running mobile app on a simulator. The agent is the operator; the user is the one whose intent is being served.

The agent is **fully informed, not clueless**. It has access to everything: the widget tree, the render tree, the navigation stack, the full state of the running app. We do not restrict what the agent can see or reach. Full access is a given.

The engineering effort is not about limiting that access. It is about making the access **context-efficient**, so the agent can act quickly, accurately, and cheaply without flooding its context window. The work is efficiency, not restriction.

The instruction and prompt layer we build (see section 6) is also not a restriction. Even with full access, an agent performs better when it is told how to use that access well. Access and guidance are separate concerns. We give the agent everything, and we also teach it how to wield it.

(Note for clarity: a "clueless user" posture does exist in our plans, but it belongs to a separate, later tool, see section 11. That tool would let teams without dedicated testers hand the agent a user persona and have it behave like a naive simulated user. Its constraints are not part of today's design and must not leak into it.)

---

## 2. What we are trying to achieve

The core goal, stated plainly:

**Let a user give an agent a task, and have the agent carry it out inside an app and on a simulator, with full context access, made context-efficient so it acts quickly, accurately, and cheaply.**

That breaks into three things the agent must be able to do:

1. **Act.** Perform any interaction a human finger or thumb could perform on the screen.
2. **See.** Hold a complete and current model of what is on the screen and in the app, expressed efficiently so it does not burn context.
3. **Orient.** Know where it is in the app, including the navigation stack and what is behind the current screen.

The agent has full access to all of this. The challenge is not gathering the information, it is delivering it efficiently. Reliability and context (token) efficiency are requirements, not nice-to-haves. A tool that is accurate but floods the context window is a failed tool. A tool that is cheap but taps dead pixels is a failed tool. Both properties have to hold at once.

A note we keep front of mind: an MCP tool is only as good as the instructions shipped with it. The reason tools like Kimi WebBridge work well is as much about the instruction layer as the binary. The grammar, the worked examples, and the gotchas we ship are half the product, not documentation, and they exist to help the agent use its full access well. This is treated as a first-class module, see section 6.

---

## 3. Guiding principles

These are the non-negotiable design rules. Everything downstream defers to them.

**Zero app modification.** The tool works on any Flutter app as-is. No package to add, no binding to initialise in `main.dart`, nothing shipped into the app binary. We read the running app from the outside via the VM service in debug mode. This is what separates us from tools that require instrumenting the app, and it is what keeps the tool production-safe and instantly adoptable.

**The device is the source of truth.** We do not maintain a separate cached model of where things are on screen. The running app on the device knows its own state. We read identity and meaning into the brain, but we resolve positions lazily, at the moment of action, against the live tree. We never cache a coordinate and trust it later, because the moment anything scrolls or animates a cached coordinate is a lie.

**The render tree is the truth layer inside the app.** Not the widget tree (immutable, disposable config) and not the element tree (the reconciliation bridge). The render tree is the only layer that knows geometry, paint order, and hit testing. That is what we read.

**Lean on the framework, do not re-derive it.** Flutter already computes hit testing every frame. We use that to answer "is this actually interactive and on top," rather than writing our own occlusion solver.

**Everything is a module.** Each part of the system is built so it can be improved or replaced without breaking the rest. The interaction layer, the perception brain, the semantic layer, and the instruction layer are independent modules with clean boundaries.

**Full access, tiered delivery.** The agent can reach everything (render tree, widget tree, navigation stack, full app state), but nothing is dumped by default. The model is a command line, or a server in front of a database. `ls` shows the current level; `ls -R` walks deeper only when asked. The server does not read the whole database to return one row; it queries exactly what was asked through a purpose-built interface. Every tool we expose works the same way: a shallow, cheap, context-efficient answer by default, with an explicit opt-in path to drill deeper. Depth is always requested and paid for only when the agent decides it is worth it. This gives a design test for every tool we add: what is its default depth, and what is its expansion path? A tool that can only return everything is designed wrong.

**Get the basics solid before the edges.** We build the common, load-bearing interactions and perceptions first. Animations, transforms, multi-touch, and custom-widget enrichment are deliberately deferred so they do not delay a working core.

---

## 4. What is in scope (now)

The agent, driving an app on a simulator, following a user's instruction.

**Interaction (the hands).** Native, OS-level interaction with the simulator, abstracted into a clean set of actions: tap, long press, double tap, swipe, drag, scroll, type text, key events, and the hardware buttons (home, lock, volume, app switcher / back on Android). Built natively per platform. iOS through a small Swift bridge over the simulator's input frameworks; Android through `adb` shell input. The interaction layer is dumb on purpose: it puts a finger where it is told and nothing more.

**Perception (the eyes).** Reading the running app's render tree to know what is currently on screen. For each meaningful element we surface two independent truths: whether it is **painted** (visible to a human) and whether it is **hittable** (actually interactive). These two diverge in real apps and the agent needs to know when they disagree.

**Orientation (the map).** Awareness of the navigation stack, so the agent knows what is behind the current screen. Depth is anchored on the Overlay, not on routes alone, so dialogs, bottom sheets, and other overlay entries are accounted for, not just pushed routes. The agent has full access to this; we surface it efficiently.

**Semantic scene description.** A plain-language mental model of the screen, derived for free from render primitives, so the agent can see what is on screen and not merely a list of tappable targets. Zero configuration required for the common case.

**Scroll-to-find as a first-class action.** Because virtualized lists only build what is near the viewport, items below the fold do not exist in the render tree until scrolled to. Reaching them is a core action, not an afterthought.

**Platform coverage.** iOS simulator and Android emulator. Debug mode.

**Screenshot as a fallback only.** Not a first-class input. Available as a backup for cases the structured path cannot describe (for example custom-painted canvas content), and as a convenience, but never the primary perception channel.

---

## 5. What is out of scope (intentionally)

These are not oversights. They are deliberate exclusions for the current stage.

**This is not a testing tool.** There is no assertion framework, no test runner, no pass/fail harness. Automated testing and record-and-replay ("recap") are noted as future work, not part of the core. We are building task execution, not verification.

**Wandering to complete a task is allowed and expected, not out of scope.** The agent can freely navigate the app to carry out an instruction. If the task is "upload a new profile image," the agent has to find its way to the profile screen, locate the edit affordance, and reach the image picker. That navigation is required, not discouraged, and we do not expect users to give instructions detailed enough to remove it. We are not here to tell the agent what it can or cannot do; it follows the task however it needs to. What is deferred is not wandering itself but **wandering-as-the-product**: the persona-driven simulated user that explores the way a specific kind of human would, for testing purposes. That is the future user-testing extension (section 11), not a restriction on today's agent.

**No animation, transform, or translation handling.** Coordinates inside animating or transformed subtrees are not specially handled in this stage. We get the static, settled-state basics right first.

**No coordinate caching.** Stated as a principle above, restated here as an explicit non-goal. We do not build a brain-side store of element positions.

**No required app annotation.** Enriching the semantic descriptions of custom widgets is future work, and when it lands it will be out-of-band (an external map the tool reads), never an edit to the app. The zero-modification principle is not negotiable.

**No non-MCP manual interface yet.** A CLI or UI version for human (non-agent) operators is future work, after the core scope is proven.

**No multi-touch on Android yet.** Pinch and rotate need raw `sendevent` on Android and are deferred. iOS gets multi-touch more cheaply (concurrent digitizer streams) but it is still not part of the first core.

**App side is the focus, not the whole OS.** The primary target is interaction inside the app. The native interaction module can technically operate anywhere on the simulator, including outside the app, but driving arbitrary OS surfaces is not the focus. If the agent leaves the app, that is a different problem we are not solving first.

**Real devices are out for now.** Native input injection plus debug-mode reading points us at simulators and emulators for the core.

---

## 6. Architecture and modules

The system is four modules behind an MCP server. The MCP server orchestrates; it holds the intelligence and the loop. The modules each do one job.

**Module A: Simulator interaction layer (the hands).**
Native, per-platform, OS-level. Abstracts the base primitive (pointer down, move, up, plus key and button events) into the action set in section 4. iOS via a Swift bridge over the simulator input frameworks; Android via `adb`. In-house, owned end to end, so no third-party update cycle can break us. Can operate outside the app, though the app is the focus.

**Module B: Perception brain (the eyes).**
Reads the render tree of the running app via the VM service. Determines what is on screen, with `painted` and `hittable` as separate flags per element. Resolves coordinates lazily at action time and converts logical to physical pixels for the interaction layer. Hands the interaction layer a concrete point only at the instant of action.

**Module C: Semantic layer (the understanding).**
Turns the render-primitive data into a compact, plain-language scene the agent can reason about. Describes elements by their derived properties (shape, colour, contained text, role), not just their interactivity. Zero-config from primitives now; out-of-band enrichment for custom widgets later.

**Module D: Instruction layer (the grammar).**
The prompt, the interaction grammar, the worked examples, and the documented gotchas shipped with the tool. Treated as a first-class module because the tool is only as good as the instructions it ships with. This is half the product.

**Orientation** (navigation-stack awareness, Overlay-anchored) sits across Modules B and C: the brain reads the stack, the semantic layer expresses it to the agent.

---

## 7. Latency and the armed-intent model

Speed is a first-class goal, not a nice-to-have. The target is to be as fast as an experienced user on a normal flow, and faster on anything that repeats. The enemy is not slow screens. It is the round-trip loop: act, stop, model wakes up, reasons, acts, stop, model wakes up again. Every stop is a full model round trip, and the model is the slow, expensive part. A human doing a task is not re-deciding every tap; the agent re-deciding every step is what turns 20 seconds of work into two minutes.

### 7.1 Two regimes: discovery and execution

There are two fundamentally different situations and they have different speed ceilings.

- **Discovery (first time through a flow).** Inherently step-by-step. The information needed to choose step N+1 only exists after step N renders. You cannot batch or pre-plan a path you have not walked. The round trips here are unavoidable; the only lever is making each one cheaper and faster.
- **Execution (a known flow).** Once a path has been walked, it is a known sequence and can be replayed fast. This is where you beat a human, because replay has no physical execution time and no per-step thinking. This regime (capture-and-replay, recap) is deferred, not today's focus.

Today's work is making **discovery** fast. We are not optimising repetitive tasks yet.

### 7.2 The core mechanic: armed intent with hit-test readiness

This is the headline design for latency, and it replaces any notion of blind batching.

The agent sees the widget tree, so it can see what *could* be interacted with and where things lead, before any of it has rendered. So the agent can commit to a symbolic intent against a target that is not yet live, for example "tap `submit`". The server holds and arms that intent. The moment the render tree brings that target into existence and it becomes genuinely interactive, the action fires automatically.

The agent does not poll, wake, check readiness, and act. It declares intent once and moves on. The action executes the instant reality allows, decoupled from the agent's attention. The settle wait still exists physically, but the agent is not spending it. The agent is never left idle.

**The readiness trigger is a real hit test, not mere existence.** An armed tap waits until the target passes a hit test at its own centre (`hittable`), not just until the key is present in the tree. This is what stops the action firing into a widget that is mounted but still behind an entry animation, or sitting under a transparent absorber, where the tap would be eaten. The framework's own hit testing is the readiness gate.

### 7.3 The try/catch contract

An armed intent is a prediction (the widget tree said this target would appear and lead here). Reality may diverge. So the contract is try/catch:

- **Try:** the armed action fires on readiness and the flow continues, with no model round trip spent waiting.
- **Catch:** if it cannot fire, the failure returns as a structured, actionable signal, never a dead end. Branches include: target not found, target present but never became hittable within the ceiling (a stall or network error), or an unpredicted screen/dialog appeared. Each catch hands the agent exactly what it needs to recover: where it is, what went wrong, and what is actually on screen now.

The agent spends model time only on two things: deciding intent, and handling catches. As long as reality matches the prediction, the flow runs at server speed. The moment it diverges, the catch wakes the agent with context. This is "one move ahead, fired the instant it is possible, caught the instant it is not." Speculation is bounded to one move, because that is as far as the widget tree can reliably see.

### 7.4 Why the widget tree comes back here

This is the concrete reason the widget tree is needed alongside the render tree. The render tree is "what is" (truth of the current screen, what you act against). The widget tree is "what is about to be" (declared structure not yet rendered: a route's `builder`, a `PageRouteBuilder`'s `pageBuilder`, unshown `IndexedStack` children, an in-flight `FutureBuilder`). Prediction reads the widget tree; action resolves against the render tree.

Prediction is free to be wrong. If the prediction holds, the next scene is near-instant because it was prepared during the settle. If it misses, the actual screen is read normally and the only cost was cheap server-side work that ran concurrently and spent no model time.

### 7.5 The other latency levers (supporting, not headline)

- **Symbolic addressing.** The agent names targets (by key, label, role), not coordinates. The server owns symbol-to-coordinate resolution against the live render tree. This deletes coordinate reasoning from every step, and it is what makes prediction tractable: "tap `submit`" plus the widget tree's knowledge of where `submit` leads is a complete prediction, whereas a raw coordinate tells you nothing about intent. Raw coordinate tapping remains as an escape hatch.
- **Lean per-step payload.** Context-efficiency is also a latency principle. A compressed scene is faster for the model to process, not just cheaper in tokens. The semantic layer earns its keep twice.
- **Concurrent preparation.** The server races ahead on the mechanical parts (arm the frame watcher, pre-read, pre-compress the predicted next scene) so the answer is ready the instant the model wants it. Settle-wait and scene-preparation overlap instead of running in series. On long multi-step flows this overlap compounds across the chain.
- **Structure predicts, data does not.** The widget tree predicts the next scene's *structure* (layout, static affordances), not its runtime *data* (an order total arriving over the network). Prediction pre-builds the skeleton; genuinely dynamic content still has to settle. We win the structural latency; we cannot win the network latency, and nothing could.

### 7.6 v1 scope for latency

The armed-intent + hit-test-readiness + try/catch mechanic, symbolic addressing, and concurrent preparation one move ahead. Capture-and-replay of known flows (the execution regime) is deferred to the recap work.

---

## 8. Observability: streaming, settle detection, and logging

### 8.1 The transition is data, not noise

When the agent acts, the screen does not change instantly. It may animate, run async builders, wait on the network, or tear down a native splash before the Flutter splash finishes. The states it passes through are not latency to hide; they are information, because a task may be *about* the transition: does the content actually load; how long does it really take on a real run rather than in theory; does an animation get cut short because a native splash teardown overlaps the loading window. None of these are answerable from the settled screen alone. The agent has full access to everything a real run produces.

### 8.2 Streaming during a tool call (verified, current)

MCP does support streaming during a single tool call, distinct from chunking the final response.

- **Progress notifications:** a live stream of notification events (progress, logs, status) while the tool executes, separate from the single final result.
- **Partial results:** structured partial content streamed mid-execution, gated by a client-set flag.

Duration guidance: under ~30 seconds, a standard tool call with progress notifications (covers essentially all screen settles); 30s–5min, the experimental Tasks primitive; beyond, an external job queue with a status-check tool.

The real constraint is client-side: the agent's MCP client must support consuming notifications for a live stream to be seen. We emit always, consume-if-supported, and never depend on live consumption for correctness.

### 8.3 Three consumption modes, coexisting

Under tiered access, the transition is just another opt-in tier:

1. **Live stream** of state-transition events, for tasks about the transition itself.
2. **Final result only**, for tasks about the outcome.
3. **Queryable history**, persisted and queried after the fact.

A consumer that ignores the stream simply gets mode 2.

### 8.4 Settle detection

Adaptive, never a fixed sleep. Watch the frame pipeline (no new frames scheduled means visually stable); since frame quiescence alone can lie (a spinner is stable while loading), also watch outstanding work and loading affordances in the freshly-read tree. Layered policy with a hard timeout: register the action, poll for N consecutive quiet frames, check for loading affordances, never block past a ceiling. On ceiling, return with `settled: false` and the loading state noted. Note the overlap with 7.2: the same readiness machinery gates armed intent, and a missed ceiling is the catch's stall signal.

### 8.5 Logging

Two separate concerns, both required.

**Agent action logging (accountability).** Every action the agent takes is logged, a complete record of what it did, in case it goes rogue or a run needs auditing. Non-negotiable for a tool that drives an app autonomously.

**Two logging modes, by design:**

- **Granular structured logs.** Machine-oriented, fine-grained events with timestamps and relational keys. Not flat text. A small segmented event store (not a log file) so it stays queryable and context-efficient, with segments kept separate by kind: frame/render events, navigation transitions, async/network state, errors, and agent actions each in their own stream, timestamped, keyed, joinable. The agent or a later tool pulls one segment at a time, scoped and cheap. This is also the substrate recap would replay.
- **Human-oriented natural-language logs.** A readable narrative for a person reviewing a run ("opened profile, tapped edit, picker appeared after 1.9s, selected first image, upload spinner 3.2s, success toast"). Derived from the structured events, not logged separately, so the two cannot drift.

**Deferred but noted:** clock discipline (capture both wall-clock and frame time, since the splash-overlap case is where they diverge) and capture cost (per-frame observation has a small debug-mode cost and must not distort the timings it measures, an argument for keeping v1 coarse).

### 8.6 v1 scope for observability

Coarse and top-level only. Capture user-visible state changes on the top-level stack (initialized, loading, animating, loaded, error) as a basic structured timeline, plus agent-action logging and a derived natural-language view. Perfectly synced logs across every async source, dialogs/overlays as first-class timeline sources, sub-component granularity, and tight clock sync are deferred. The coarse timeline answers most real questions and proves the model.

---

## 9. Locked decisions

- Render tree is the in-app source of truth for *what is*; the widget tree is the prediction surface for *what is about to be*. Action resolves against the render tree; prediction reads the widget tree.
- Device is the source of position; coordinates resolved lazily, never cached.
- Two separate visibility truths per element: `painted` and `hittable`.
- Hit testing is delegated to the framework, not hand-rolled, and is the readiness gate for armed intent.
- Depth is anchored on the Overlay, not routes alone.
- No assumption that every screen has a Scaffold.
- Zero app modification; debug-mode VM service only.
- Native, in-house interaction layer per platform (Swift for iOS, `adb` for Android).
- Modular architecture, four modules behind an MCP server.
- Instruction layer is a first-class module.
- The agent addresses targets symbolically (key/label/role) by default; the server resolves to coordinates. Raw coordinate tapping is an escape hatch.
- Latency model is armed intent: declare symbolic intent against a possibly-not-yet-live target, fire on hit-test readiness, try/catch on divergence, agent never idle. Speculation bounded to one move ahead.
- The transition between screens is captured as data, not hidden; streaming is an opt-in tier, the settled result is always returned.
- Agent actions are always logged; logging comes in two modes (granular structured, and human-oriented natural language derived from it).
- **Supported Flutter floor:** latest stable + one before (current stable at time of writing: 3.44). Policy: as new Flutter stable ships, the floor moves up. No legacy version branches in Module B.
- **App lifecycle:** hybrid — *attach* to a VM service URI is the primitive; a thin session-manager module wraps `flutter run` to *launch* and then attach. Both modes shipped in v1. Reuse battle-tested launch/attach patterns from `flutter_network_mcp`.
- **MCP transport:** stdio in v1. Code structured so streamable HTTP can drop in later without a rewrite.
- **Element identity scheme:** every element has a unique, *stable* symbolic id. The agent never has to disambiguate at action time because names never collide. Generation: developer-assigned `Key` when present; otherwise a descriptive context-derived suffix (`submit_in_bottomsheet`) when ancestors give enough signal; otherwise a short deterministic hash (`submit#a3f1`). Stability across reads is required (same widget in same place ⇒ same id, every time) — IDs are derived from stable properties (tree path + ancestor labels + key), never random.
- **Armed-intent state machine:** single armed slot, at most one move ahead (matches §7.2). Arming a second while one is pending → structured error. Hard ceiling reuses settle detection (§8.4). Scene reads and cancel-armed allowed while armed; immediate (non-armed) actions are blocked while an intent is armed (they would race).
- **iOS interaction bridge:** Swift, against private `CoreSimulator` + `SimulatorKit`. Modern Xcode (≥14) replaced the legacy `-[SimDevice sendEvent:]` API with `SimulatorKit.SimDeviceLegacyHIDClient.send(message:freeWhenDone:completionQueue:completion:)` taking an `UnsafePointer<IndigoHIDMessageStruct>` built via SimulatorKit's exported C function `IndigoHIDMessageForMouseNSEvent`. The IO subsystem above this (`SimDevice.io.ioPorts` → `SimDeviceIOClient`) is an XPC overlay (`ROCKRemoteProxy`); the legacy HID client is the canonical glint entry. *Per-Xcode reverse engineering is the maintenance model* — message offsets and required fields shift between Xcode majors. Compat matrix is §13.
- **`painted` v1 definition:** element has non-empty paint bounds AND bounds intersect the viewport AND no *direct* ancestor sets `opacity: 0` or `Visibility(visible: false)`. Deferred: transitive opacity multiplication, custom clip paths, non-identity transforms, in-flight animation states.
- **MCP server language:** Dart, on `package:dart_mcp` + `package:vm_service` + `package:dtd`. Reuses DTD discovery, attach lifecycle, structured response shapes (`summary` / `nextSteps` / `warnings`), and AOT install flow from `flutter_network_mcp`.

---

## 10. Open decisions

- **Widget-tree prediction surface for unrendered subtrees** — reading a route's `builder`, a `PageRouteBuilder`'s `pageBuilder`, unshown `IndexedStack` children, an in-flight `FutureBuilder`. P0 confirmed the inspector exposes the *current* widget tree exhaustively, but the predictive surface (what's *about to be*) lives in builder closures that haven't run yet. Approach (probably: evaluate `route.builder` invocations against a synthetic context, server-side) to be pinned during P6 (armed intent).

### Pins from P0

- **Render-tree dump:** `ext.flutter.debugDumpRenderTree` (verified on Flutter 3.44 stable, both platforms).
- **Widget tree (current):** `ext.flutter.inspector.getRootWidgetTree` with `{isSummaryTree: 'true', withPreviews: 'true', fullDetails: 'false'}`. Returns `{result: <DiagnosticsNode JSON>}`. Text previews appear as `textPreview` on `RenderParagraph`-backed elements — the smoke uses this to read the counter.
- **Fallback chain when `getRootWidgetTree` is absent:** `getRootWidgetSummaryTreeWithPreviews` → `getRootWidgetSummaryTree`. P0 confirmed all three exist on 3.44.
- **Isolate selection:** the Flutter isolate is the first one whose `extensionRPCs` contain any `ext.flutter.*` extension. Counts observed on the counter fixture: 63 `ext.flutter.*`, 32 `ext.flutter.inspector.*`.

---

## 11. Roadmap and future possibilities

This section is what we hope to achieve beyond the core, and what could plausibly come next. It is part roadmap (what is next for us) and part open possibility (things worth not forgetting). Nothing here is part of today's build. It is captured so the thinking is not lost.

### 11.1 The user-testing extension (simulated personas)

This is the big one, and it is a whole segment in its own right, not a feature. It is a separate tool built on top of the core, aimed at teams that do not have dedicated testers. The idea: the user hands the agent a user persona, and the agent exercises the app the way that persona would, including the wandering, hesitation, and naive-user behaviour a real person of that type would show. This is the "clueless user" posture that explicitly does not belong in the core. It is user testing, not assertion-based testing.

Why it is a segment and not a feature: making this work means building several things that the core does not need.

- **Persona identity and storage.** Personas have to be defined, named, stored, and reused. A persona is a durable object with traits, goals, tech-savviness, patience, demographics, and behavioural tendencies. That is a data model and a store, not a prompt.
- **A persona-generation system.** A really good instruction system where the user can supply a brief and get a fully-formed persona prompt back. The user should be able to copy a prompt, hand it an agenda, and get an agent that acts as that persona consistently. This needs to be excellent, because the quality of the persona is the quality of the test.
- **A library of persona prompts.** Multiple ready-made prompts the user can pick from or clone, so a user can equip an agent with a persona and have it behave properly out of the box.
- **The behavioural instruction layer.** The prompts that make a persona behave consistently across a whole session, so the simulated user does not drift out of character.
- **Testing and recap mechanics around it.** Recording what the persona did, where it got stuck, what it could not find, and replaying or reporting that as a usability signal.

This is going to be a genuinely fun build, but it is firmly future. The only thing the core owes it is clean module boundaries so it can be built on top without a rewrite.

### 11.2 Recap (record and replay)

Record the sequence of actions an agent or user takes, then replay them later, with metrics. Closer to user testing than to assertion-based testing. A natural companion to the persona tool, and partly shared infrastructure.

### 11.3 Non-MCP interface

A CLI or a UI for human (non-agent) operators who want to drive the same capabilities directly. After the core is proven.

### 11.4 Custom widget semantic enrichment

Better plain-language descriptions of custom (non-primitive) widgets. When it lands it will be out-of-band: an external map keyed by `runtimeType` or `Key` that the tool reads, never an edit to the app. The zero-modification principle holds.

### 11.5 Animation and transform awareness

Correct coordinate resolution for elements inside animating or transformed subtrees, using the framework's transform mapping. Deferred so the static, settled-state basics ship first.

### 11.6 Multi-touch gestures

Pinch and rotate. Cheap on iOS (concurrent digitizer streams), and on Android via raw `sendevent` to drive concurrent finger slots.

### 11.7 Broader OS-level interaction

Driving surfaces outside the app on the simulator. The native interaction layer can technically already do this; making it a supported, first-class capability is future.

### 11.8 Real device support

Beyond simulators and emulators. Constrained by native input injection and debug-mode reading, so it is a later, harder target.

---

## 12. Phase plan

The plan delivers the v1 scope in eight phases. Each phase ends at a demoable artefact and a verification gate. We do not start phase N+1 until phase N's gate passes.

**Phase 0 — Foundation. ✅ Complete.**
Repo skeleton, license, README in place. Pick MCP server entrypoint shape (Dart `bin/glint.dart`). Pin VM service access path for the supported Flutter floor (closes the open decision in §10). Stand up a smoke harness that: launches the fixture app via `flutter run --machine` (proving the launch-wraps-attach pattern early), attaches via VM service, dumps 5 render nodes, and taps.
Tap delivery in P0 is platform-honest: `simctl` has no input injection — OS-level iOS taps require the private CoreSimulator/Indigo HID bridge, which is P2's deliverable. So P0 taps via `adb shell input tap` on Android (true OS-level) and via in-app pointer dispatch through VM-service expression evaluation on iOS (interim; replaced in P2).
*Verify:* one-command script launches the counter fixture, dumps a partial render tree, locates the increment button lazily from the live tree, taps it, and the counter increments. Both platforms green (Android OS-level, iOS interim-synthetic).

*Lessons banked into P1/P2:*
- VM-service `evaluate()` accepts EXPRESSIONS only — no statement-block lambda bodies. Module B must do tree walks server-side (walking inspector JSON) rather than via in-VM evaluate. P0 used a fixture-side helper to sidestep this; Module B will not.
- A backgrounded Android app gets a zero-size surface from the OS; layout reads return garbage until the app is foregrounded. Foregrounding the target is an interaction-layer responsibility (Module A in P2). The smoke harness's `_ensureAndroidForeground` is the seed of that helper.

**Phase 1 — Module B core (perception minimum). ✅ Complete.**
Render-tree walker over VM service. `painted` and `hittable` flags per the v1 definition. Lazy coordinate resolution + logical-to-physical pixel conversion. Stable id generation (§9 element identity scheme). No semantic layer yet — output is raw structured nodes.
*Verify:* on a counter app and a list-detail demo app, the dumped scene matches what's actually on screen and what's actually tappable. `painted` vs `hittable` divergence demonstrable on a known case (e.g. a button under a transparent absorber).

*Lessons banked into P3+:*
- **VM `evaluate()` accepts EXPRESSIONS — including immediately-invoked lambdas, cascades, and record literals — but NOT statement-block function bodies.** A lambda body must be `=> expression`. Verified empirically: `((HitTestResult r) => ((WidgetsBinding.instance..hitTestInView(r, c, viewId)), r.path.any(...)).$2)(HitTestResult())` works. The arrow-body + record-literal pattern is the canonical way to thread side effects through a single eval. (And: raw newlines inside the expression are treated as EOF — keep it single-line.)
- **The inspector's summary tree is ~10× smaller than the full tree** (counter+flags-lab fixture: 11 KB summary vs 2.5 MB full). Summary stays the agent-facing read surface in P3; full tree is server-internal only.
- **`textPreview` is a node-local property, not part of identity.** Stable id generation must NOT key on it — proven by Gate 2 (counter ticks, ids hold).
- **`Opacity(opacity: 0)` is the canonical painted=false, hittable=true case.** Flutter's RenderOpacity does not override hit testing, so taps still land. The matrix `(painted, hittable) ∈ {(T,T), (F,T), (T,F)}` is empirically demonstrable on a single screen — keep this as the canonical demo for Module B regressions.
- **The agent-facing id scheme passes the "two consecutive instances" test for free.** Three `SizedBox`es in the same Column got `sized_box_in_flags_lab#mqif`, `#sjjf`, `#a6gf` automatically — descriptive scope + hash fallback Just Works without per-shape tuning.

**Phase 2 — Module A core (interaction minimum).** ✅ Core path green; full action-set fill-out in the Swift bridge is P2.2.
iOS Swift bridge against `CoreSimulator` for tap/swipe/type/buttons. Android `adb shell input` equivalents. Action set abstraction. Interaction layer accepts only resolved coordinates from Module B; agent-facing API is symbolic ids.
*Verify:* tap, swipe, type, and a hardware-button event each work on both platforms, addressed by stable id resolved by Module B. Manual smoke covers the action set in §4.

*Lessons banked:*
- **VM-service `valueAsString` is a 128-char preview.** Longer strings need `service.getObject(isolateId, ref.id)` to refetch the full content. Bit us when the Pixel 8's logical viewport (`411.42857142857144`) pushed our geometry JSON past the limit. Module B's resolver now refetches on `valueAsStringIsTruncated`.
- **Backend contract: `summary` / `nextSteps` / `warnings`** — same envelope as `flutter_network_mcp`. Errors carry a typed `errorClass` (`UnresolvedTarget`, `NotHittable`, `UnsupportedBackendAction`, `BackendToolError`, `GeometryResolveError`) so the agent branches on cause without parsing prose.
- **Permissive-by-default hittable.** The Interactor surfaces `hittable=false` as a warning, not a refusal. Strict mode (`refuseNotHittable=true`) flips it to `errorClass:"NotHittable"`. §3 "agent gets everything; structured response shows what was found" — let the agent decide.
- **iOS uses logical points, Android uses physical pixels.** The Interactor speaks physical pixels uniformly; `IosSimBackend` divides by DPR before handing the logical coords to `glint-iossim`. Keeps the orchestrator backend-agnostic.

**Phase 3 — Module C minimum (semantic scene).**
Compact plain-language scene derived from render primitives. Overlay-anchored navigation-stack awareness (§4). Output is the agent's actual reading surface.
*Verify:* hand-eyeball the scene description against three real apps of different shape (form-heavy, list-heavy, modal-heavy). Output is short enough to be context-efficient, complete enough to act on without re-reads.

**Phase 4 — MCP server v0.**
Stand up the MCP server over stdio. Tools: `get_scene`, `tap`, `long_press`, `swipe`, `drag`, `scroll`, `scroll_to_find`, `type`, `key`, `hardware_button`. Structured response shape (`summary` / `nextSteps` / `warnings`) ported from `flutter_network_mcp`. No armed intent yet — every action is synchronous.
*Verify:* a fresh Claude conversation, given only Module D's prompt + the MCP tools, drives a real app through a 3-step task end-to-end. Slow round trips are expected at this stage.

**Phase 5 — Module D v0 (instruction layer).**
Tool grammar, worked examples, gotchas. Instructions emphasise structured tool calls against stable ids (not natural-language target descriptions). Includes the documented behaviour of the resolver, the id scheme, and recovery patterns when actions fail.
*Verify:* a fresh agent with no prior memory completes 3 sample tasks of increasing complexity. Catches and recoveries are handled correctly without human help.

**Phase 6 — Latency: armed intent.**
Settle detection: frame-pipeline quiescence + loading-affordance check + hard ceiling (§8.4). Widget-tree prediction: read the predicted next scene's structure concurrently while the current settle runs. Armed intent state machine: single slot, hit-test readiness gate, try/catch contract (§7.2–§7.3).
*Verify:* on a known multi-step flow, measured end-to-end wall-clock drops materially vs Phase 4 baseline. Catches fire correctly on intentionally-broken predictions (route mocked to push a different screen).

**Phase 7 — Observability v0.**
Coarse top-level state-transition timeline (initialized / loading / animating / loaded / error). Agent action log (granular structured). Natural-language log view derived from the structured events. Streaming-during-tool-call emitted as MCP progress notifications, consumed-if-supported (§8.2).
*Verify:* a recorded run of a real task reads as a coherent narrative ("opened profile, tapped edit, picker appeared after 1.9s, …"). Structured log answers "what did the agent do at second 14?" cleanly. Stream events visible in a client that consumes them.

Action-set fill-out (long-press, drag, hardware buttons, `scroll_to_find`) and screenshot fallback are woven into the modules that own them, not their own phase.

---

## 13. Xcode compatibility matrix (Module A iOS bridge)

Module A's iOS bridge (`native/ios_sim_bridge/`) targets a single Xcode major release per backend. The maintenance model is per-release reverse engineering of `IndigoHIDMessageStruct`'s byte layout in `SimulatorKit.framework`, then patching the right fields and dispatching via `SimDeviceLegacyHIDClient.sendWithMessage:`. Each row below is a discrete contribution opportunity — community PRs welcome.

| Xcode | iOS Sim runtime | Status | Notes |
|---|---|---|---|
| 26.x | 26 | **✅ tap working** | Layout: 24-byte outer envelope (all zero), then `innerSize=0xA0` @ 0x18, `eventType=2` @ 0x1C, payload[0] @ 0x20, payload[1] (digitizer mirror) @ 0xC0. Touch xRatio @ 0x3C / 0xDC, yRatio @ 0x44 / 0xE4, payload[1].touch.field1=1 @ 0xCC, field2=2 @ 0xD0. Target=0x32, eventType down=1, up=2. Total message 0x160 bytes. |
| ≤14 | ≤14 | reference only (idb's FBSimulatorIndigoHID.m); not targeted by glint v1 | Same offsets minus the 24-byte outer envelope. |

**Investigation log lives in commits to `native/ios_sim_bridge/`**. Each Xcode release goes through:
1. `nm -gU` on SimulatorKit/CoreSimulator to confirm exported `IndigoHID*` symbols.
2. `objc_copyProtocolList` + `class_copyMethodList` (the `dump-protocols` / `dump-classes` / `dump-class-methods` commands in `glint-iossim`) to map the live ObjC class graph.
3. Hex-dump the message returned by the builder to spot layout shifts vs prior release.
4. Try the 1-payload send; if no touch, port idb's 2-payload reconstruction and retry.
5. Iterate on `xRatio/yRatio` offsets if simulator still doesn't see the touch.
6. Once green, lock the per-Xcode Swift module behind a runtime version detector.

---

## 14. Milestone tracking

Use this section as the running checklist. Update status as work lands.

| Module | Component | Status |
|---|---|---|
| A | iOS native interaction bridge (Swift) | ✅ tap on Xcode 26 / iOS 26.5 via SimDeviceLegacyHIDClient (see §13 compat matrix) |
| A | Android interaction via adb | ✅ `AdbBackend` (`lib/src/interaction/backends/adb_backend.dart`) — tap/longPress/swipe/typeText/hardwareButton all wired |
| A | Android foregrounding helper | P0 seed (`_ensureAndroidForeground` in `tool/smoke.dart`); MCP wrapper (P4) owns the policy |
| A | Action abstraction (tap, swipe, type, buttons) | ✅ Sealed `Action` hierarchy + `Target` + `InteractionBackend` contract + `Interactor` orchestrator; tap fully verified on both platforms, swipe/typeText/hardwareButton wired in `AdbBackend`. `IosSimBackend` raises `UnsupportedBackendAction` for the swift-bridge gaps until P2.2 fills them in. |
| B | Render-tree reader over VM service | ✅ `InspectorClient` (summary + full) |
| B | painted / hittable flagging | ✅ painted from JSON + ancestor walk; hittable via real `hitTestInView` |
| B | Lazy coordinate resolution + DPR conversion | ✅ single-eval `CoordinateResolver` (geometry + painted + hittable in one round trip) |
| B | Stable id generation | ✅ snake_case + descriptive scope + FNV-32 hash fallback; 8 unit tests pass |
| B | Navigation-stack / Overlay awareness | not started |
| C | Zero-config primitive describer | not started |
| C | Plain-language scene output | not started |
| D | Interaction grammar + examples + gotchas | not started |
| — | MCP server orchestration + loop | not started |
| — | scroll-to-find action | not started |
| — | Settle detection (frame quiescence + loading affordance) | not started |
| — | Symbolic addressing (key/label/role resolution) | not started |
| — | Armed intent + hit-test readiness trigger | not started |
| — | Try/catch divergence handling | not started |
| — | Widget-tree prediction + concurrent scene prep | not started |
| — | State-transition streaming (progress notifications) | not started |
| — | Segmented structured event store | not started |
| — | Agent action logging | not started |
| — | Natural-language log view (derived) | not started |
