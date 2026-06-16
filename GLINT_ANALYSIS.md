# Glint — Test Run Analysis

Living doc. Each run's findings appended. Structured as: **What happened · Why (the reasoning) · How to fix.** Edited as we learn more.

---

# Run 1 — AeTrust registration flow

**Date:** 2026-06-15 · **Session:** 5191608a · **Model:** Sonnet (thinking blocks came back empty — verify thinking was actually enabled) · **Duration:** ~26 min (18:29 → 18:55, manually stopped) · **Outcome:** FAILED — stuck on the date-of-birth picker, never completed.

## Timeline
- **18:29–18:42 (~13 min):** Cold start. Launch app, wait for build, find VM URI, attach. Large upfront cost before any real work.
- **18:42–18:43:** Login screen → tapped "Create one" → hit a "Welcome back, Lukas" resume modal (previous in-progress registration).
- **~18:43:** Navigated past modal via "Start over", reached `/register`, filled first/last name successfully.
- **18:43–18:55 (~12 min):** Stuck on the date-of-birth picker. ~15 distinct workarounds attempted, none worked. Manually stopped.

---

## FINDING 1 — Overlay blindness (CRITICAL, root cause)

### What
`get_scene` reads the current route's widget subtree but **not the Overlay stack layered on top of it**. Every overlay-layer element is invisible to Glint:
- the "Welcome back" resume modal
- the `showDatePicker` dialog
- and by extension: `showDialog`, `showModalBottomSheet`, dropdown menus, snackbars, tooltips

The agent confirmed this itself, repeatedly:
> "The modal IS open but Glint's scene doesn't show it — dialog overlays are in a separate layer."
> "The date picker IS open — confirmed in the full widget tree. Glint just doesn't see it via semantics."

### Why it happened (the reasoning)
Overlays are **not** a separate rendering system in Flutter. An `OverlayEntry` is just another widget subtree mounted into the `Overlay`'s element tree, which is part of the **same render tree** Glint already reads via the VM service. A `showDatePicker` dialog has real `RenderObject`s, real positions, and is hit-testable — it's right there in the tree.

So the bug is almost certainly that **`get_scene` traverses from the current route's content node, not from the root.** It reads the screen *below* and stops before reaching the overlay entries stacked *above*. The dialog is in the tree; Glint isn't walking up to where it lives. Proof: the agent could see the dialog via the raw widget inspector the whole time — only Glint's scene reader was excluding it.

This is the exact risk the source-of-truth doc named ("depth is anchored on the Overlay, not routes alone") — it simply wasn't implemented yet.

### The cascade it caused
This single root cause produced nearly everything else in the run:
1. Agent couldn't see the overlay →
2. couldn't tell whether its taps were landing on the dialog or the dead screen beneath →
3. started guessing (15 workarounds) →
4. each guess = a full model round trip (tap → wait → get_scene → read source → reason → retry) →
5. 12 minutes of thrashing and an eventual manual stop.

Fix sight, and the thrash, much of the latency, and part of Finding 2 shrink with it.

### How to fix
1. **Traverse from the root view / root Overlay downward**, not from the route's content node. Include every mounted overlay entry in the scene.
2. **Order overlay entries by stack depth** so the agent knows what's on top (the dialog) vs underneath (the base screen).
3. **Represent the modal barrier correctly using the `painted`/`hittable` split** (see Finding 2 — they're linked): when a modal is up, the base screen is still `painted` but no longer `hittable` because the barrier absorbs touches. The scene should show: dialog on top = interactive; screen beneath = visible-but-not-hittable. This directly tells the agent "don't tap the screen under the dialog, it's blocked," which it never knew here.
4. Screenshots remain the fallback only for genuinely opaque content (custom-painted canvas) — never needed for overlays. This is a traversal fix, not a perception gap.

---

## FINDING 2 — Tap registers but `onTap` doesn't fire (SERIOUS)

### What
Repeatedly, a tap returned success metadata — `ok:true, painted:true, hittable:true`, correct physical center — but the widget's handler (`_pickDob`, `onTap`) never fired. The physical tap "landed" by Glint's own report, yet the app did nothing.

### Why it happened (the reasoning)
Two candidate causes, likely both in play:

**(a) Modal barrier absorbing the tap (linked to Finding 1).** When the date picker / resume modal was open, the agent — blind to the overlay — was tapping coordinates on the screen *beneath* the modal barrier. A modal barrier is `painted`-transparent but `hittable` — it eats the touch. So `hittable:true` was technically true (something hittable was there: the barrier), but the touch went to the barrier, not the intended widget. Glint reported success because the point *was* hittable; it just wasn't hittable as *the target the agent meant*. This means part of Finding 2 is really Finding 1 in disguise.

**(b) Gesture-completeness / timing fidelity.** Even setting overlays aside, "tap lands but `onTap` doesn't fire" is the classic symptom of an **incomplete or too-fast synthesized gesture**. Flutter's tap recognizer wants a proper pointer-down → (small delay) → pointer-up sequence at a stable position. If Glint emits a single event, or down/up with near-zero delta time, or without the right pointer kind, the recognizer may not classify it as a tap — especially for `InkWell`/`GestureDetector` which compete in the gesture arena. The run showed this persisting even after swapping `InkWell` → `GestureDetector` and adding `HitTestBehavior.opaque`, which points at the injected gesture itself, not the widget.

### How to fix
1. **First, fix Finding 1** — once the agent can see overlays and the hittable-barrier state, a chunk of these "didn't fire" cases vanish because it stops tapping blocked screens.
2. **Audit the injected tap as a complete gesture:** pointer-down → hold a realistic few-ms → pointer-up at the same point, correct pointer kind (touch), single pointer id. Verify against what a real finger produces (the log-stream verification harness we discussed: real tap vs injected tap, diff the HID/pointer signature).
3. **Add a post-action truth signal** so "did it fire?" isn't guessed (see Finding 5 — return what changed). The agent should never have to infer whether a tap worked.
4. Distinguish in the `tap` return between "a hittable point existed here" and "the target you named received the event." Right now `hittable:true` conflates them.

---

## FINDING 3 — Latency is loop-thrashing + cold start, not per-call Glint (IMPORTANT, but mostly downstream)

### What
The 26-minute run *felt* like Glint being slow, but individual Glint calls were fast: `settled in 254ms`, taps near-instant, `get_scene` quick. The wall-clock went to (a) ~13 min cold start and (b) ~12 min of round-trip thrashing on the stuck step.

### Why it happened (the reasoning)
- **Cold start (~13 min):** launching the app, waiting for the debug build, polling for the VM URI, attaching. This is unavoidable boot cost, but it was inside the timed run and dominated the first half.
- **Thrashing (~12 min):** every failed date-picker attempt was a full model round trip. The model was the slow part, exactly as the latency design anticipated. And it thrashed *because* it was blind (Finding 1) — it couldn't see why a tap failed, so it tried another approach, round-tripping each time. Latency here is a **symptom** of the sight problem, not an independent disease.

### How to fix
1. **Fix sight (Finding 1)** — removes most of the thrashing round trips at the source.
2. **Add a change/diff signal to actions (Finding 5)** — collapses the tap→wait→get_scene→compare dance into one call, cutting round trips on the happy path too.
3. **Separate cold start from the timed flow** — pre-warm the app and attach *before* the measured portion, so tests measure the flow, not the boot. (Process change, also a product consideration: in Glaze, the simulator/app should be kept warm.)
4. **Reduce ToolSearch churn (Finding 4)** — fewer re-discovery round trips.
5. Only after the above, revisit genuine per-call latency — but current evidence says Glint's calls are not the bottleneck.

---

## FINDING 4 — ToolSearch churn (MODERATE)

### What
The agent invoked `ToolSearch` repeatedly throughout the run, re-discovering Glint tools it had already used (e.g. re-searching for `tap`, `get_scene`, `session`, etc.).

### Why it happened (the reasoning)
The tool surface wasn't resident enough in the model's working context — the tools are deferred/searched rather than always-present, so the model kept re-fetching their definitions mid-task. Each re-search is a wasted round trip that adds latency and clutters the trace without doing any app work.

### How to fix
1. Make the core Glint tools (attach, get_scene, tap, type, scroll, wait_for_settle, resolve) **resident in context** rather than search-gated, so the agent doesn't relearn them.
2. If the deferred-tool mechanism must stay, **front-load the full Glint tool set once** at attach time so a single search surfaces all of them together.
3. Tighten tool descriptions so one lookup is sufficient and the agent doesn't re-search for clarification.

---

## FINDING 5 — No "what changed?" primitive; failure messages are generic (MODERATE→HIGH leverage)

### What
Two related gaps in the tool *surface*:
- **No single answer to "did my last action do anything?"** The agent manually ran tap → wait_for_settle → get_scene → compare scenes, every time, to detect whether an action changed the screen. A 3–4 call dance to answer one question.
- **Failure messages are generic.** `scroll_to_find` "not found" only suggested "try a different direction / increase maxScrolls / read the scene." It didn't say *why* — target doesn't exist vs is in an unseen overlay vs is off-screen. The agent couldn't tell, so it guessed.

### Why it happened (the reasoning)
The tool surface was designed for the **happy path** — when things work, the vocabulary (attach/get_scene/tap/type/scroll) is clean and legible, the scene format is genuinely good, and the `tap` return metadata (`painted`/`hittable`/center/DPR) is well chosen. But the **failure path and expansion path** are thin. An agent is only as effective as its ability to recover from failure, and recovery depends entirely on the tool explaining what's true. Generic failure text forces guessing; guessing is the thrash. Likewise, with no drill-down tool, the agent's only way to get *more* detail was to drop to bash and read the Dart source — a heavy escape hatch that burned minutes.

### How to fix
1. **Return what changed from actions.** A `tap`/`type` should optionally return a scene-diff or a summary of what changed (route change, new overlay, focus change, nothing). Collapses the multi-call detection loop into one call — big latency win and removes ambiguity.
2. **Make failure messages diagnostic, not generic.** "not found" should distinguish: not in tree at all / present but in an overlay / present but off-screen / present but not hittable. The agent's next move depends entirely on which.
3. **Add a drill-down / `describe` tool** (the expansion tier from the `ls` tiered-access principle): given a target or region, return deep detail — full subtree, exact rect, hittability, what's on top of it. This keeps the agent inside Glint instead of spelunking source files, which is what cost ~minutes here.
4. **Distinguish "a hittable point" from "the named target received the event"** in returns (ties to Finding 2).

---

## FINDING 6 — No survival across hot reload / restart (MODERATE)

### What
After a hot restart late in the run: `wait_for_settle failed`, then `get_scene failed`, requiring a full manual re-`attach` with the bridge path.

### Why it happened (the reasoning)
Glint's VM-service connection is tied to the app's pre-restart isolate/connection. A hot reload or restart tears down or replaces that, and Glint doesn't detect the drop or re-establish automatically — it just fails dead until re-attached by hand. For a tool whose own workflow involves editing-and-reloading the app (and Glaze will do this constantly), losing the connection on every reload is a real reliability hole.

### How to fix
1. **Detect connection loss** and surface it as a clear, recoverable error ("connection dropped after reload, re-attaching…") rather than a bare `failed`.
2. **Auto-reconnect** on reload/restart: re-resolve the VM URI and re-attach transparently, preserving the session.
3. Make `wait_for_settle` / `get_scene` return a typed "not connected" state the agent can act on, instead of opaque `failed`.

---

## Tool-call surface assessment (separate axis from bugs)

**What worked (happy path is good):**
- Clean, legible verb vocabulary: attach, get_scene, tap, type, scroll, wait_for_settle, scroll_to_find, resolve.
- Scene output format is genuinely strong — indented tree, `#ids`, `* button` markers, compact and readable.
- `tap` return metadata is well-designed: `painted`, `hittable`, physical center, DPR. Right things surfaced.
- When the loop was healthy, the agent used the tools fluently and correctly.

**Where it's thin (failure + expansion paths):**
- Failure messages are generic → agent guesses → thrash (Finding 5).
- No "what changed?" signal → wasteful multi-call detection dance (Finding 5).
- No drill-down/`describe` tool → agent escapes to bash + source reading (Finding 5).
- Tool set not resident → ToolSearch churn (Finding 4).
- `hittable:true` conflates "point is hittable" with "target got the event" (Finding 2).

**Principle:** the tools are only as good as their behavior on failure. Happy-path design here is solid; failure-path and expansion-path design is what turned a small problem (one date picker) into a 12-minute thrash.

---

## FINDING 7 — Native surfaces are a real, separate blind spot (FUTURE CAPABILITY, not a Run-1 bug)

### What
When the app crosses a **method channel** into native code, the resulting UI is **not Flutter** and is **not in the render tree at all**. Native photo picker (`UIImagePickerController` / gallery intent), share sheet, native permission dialogs, contacts picker, native maps, in-app-purchase / StoreKit sheets, some native date pickers — all of these are OS-rendered surfaces sitting on top of the Flutter app. The render-tree reader sees nothing there because there is nothing Flutter to see.

This did **not** cause the Run-1 failure (that date picker was a Flutter `showDatePicker` — an in-tree overlay, Finding 1). But it is a real capability gap that will appear the moment a flow touches native UI (image upload, permissions, share, IAP), which most real apps do.

### Why this is a DIFFERENT kind of blindness than Finding 1
- **Finding 1 (overlay) is a FALSE blind spot:** the content was in the tree, Glint just wasn't traversing to it. Fixable by reading from the root.
- **Finding 7 (native) is a REAL blind spot:** the content isn't in the Flutter tree *at all*, because it isn't Flutter. No amount of better Flutter traversal reaches it. It needs a *different perception source*.

Do not conflate them. The fix for one does nothing for the other.

### The two halves of a method channel
- **Dart side — READABLE.** `MethodChannel(...).invokeMethod('pickImage')` originates in Dart, runs through the isolate, and is observable via the VM service. You can see *that* a channel call happened, *which* channel/method, and *what* arguments.
- **Native side — NOT READABLE via Flutter.** Once the call crosses into native iOS/Android, it leaves Flutter entirely. The surface it shows is OS-rendered, outside the render tree and the VM service.

### How to fix (intuitive implementation)

**Two perception modes, switched by a handoff signal.**
- **Flutter mode (default, ~95% of the time):** read the Flutter render tree (incl. overlays per Finding 1). This is the normal Glint.
- **Native mode:** when a native surface is up, read the **OS accessibility tree** instead — iOS AX hierarchy (via idb / XCUITest), Android `uiautomator` dump. The OS exposes its *own* element tree for its *own* screens. So a native photo picker IS readable — just through the OS accessibility API, not the Flutter VM service. Screenshot+vision stays the last-resort fallback only.

**Detecting the handoff — signal fusion (combine, don't pick one).**

Not an either/or. Several signals each cover a different blind spot the others leave; combined, they let Glint *classify* the episode rather than guess. Each alone is ambiguous; together they're precise.

- **Method channel call (out) — intent + identity + trigger.** Tells you native UI is *about to* appear and often *what* (`pickImage`, `share`, `requestPermission`). But a channel call doesn't guarantee a surface appears (some return data silently) and fires slightly before the surface is up. Predictive, not confirmed. *Labels* the episode.
- **App lifecycle leaves `resumed` (→ inactive/paused) — confirmed handoff.** Definitively says Flutter is no longer the active surface. But ambiguous about cause: could be a native picker, an incoming call, backgrounding, or a system notification. Confirmed, but *unlabeled*.
- **Render tree freezes / becomes unreachable — corroboration.** Frames stop scheduling, scene reads stall. Independently confirms Flutter is genuinely inactive, regardless of lifecycle reporting.
- **Method channel result (back) — the OUTCOME.** When control returns, the original call's future completes with the result (picked file vs cancelled). This is the *only* signal that tells you what the native episode actually produced — neither lifecycle nor the tree gives you this. The episode's outcome returns through the same channel that opened it.
- **Lifecycle returns to `resumed` + tree resumes frames — confirmed return.**

**Why fusion beats any single signal — disambiguation:**
- Photo picker = lifecycle change **AND** a media channel fired **AND** a result returns → switch to native reading, anticipate a gallery grid.
- Phone call / interruption = lifecycle change **but NO** channel call, **no** picker surface → do **NOT** switch to native reading; just wait for resume.
A single signal can't tell these apart and forces a guess. The combination *classifies* them. This is the core value of combining: correct behavior in cases one signal alone conflates.

**The full bracket, end to end:**
1. Channel call out → *what's coming* + trigger (early).
2. Lifecycle leaves `resumed` → confirmed handoff.
3. Tree freezes → corroborates Flutter inactive.
4. → switch to Native mode (OS accessibility tree). [native episode]
5. Lifecycle returns to `resumed` → confirmed return.
6. Channel result returns → *the outcome* (picked / cancelled / which file).
7. Tree resumes frames → corroborates Flutter active. → switch back to Flutter mode.

**Feeds prediction:** because fusion tells you it's *specifically* a photo picker and it's *confirmed* up, Glint can pre-switch to native reading AND anticipate the shape of what it'll find — rather than discovering it cold. Richer signals → more confident prediction and preparation (ties to the armed-intent / concurrent-prep model: prediction is only as good as the signals feeding it).

**Implementation notes:**
- Subscribe to lifecycle state via the VM service (Flutter exposes lifecycle through the binding; observe the transition, don't poll).
- Native mode reuses the simulator interaction layer you already have for *acting* (native taps already go through idb/simctl/adb) — you're only adding native *reading* (the OS accessibility tree) alongside the native acting you can already do.
- Keep the scene format identical across modes if possible, so the agent doesn't have to reason differently — it just gets "a scene," whether sourced from Flutter or the OS. The source is an implementation detail; the agent sees one consistent surface.
- Scope: **not now.** Run-1 failures are pure-Flutter. This is captured so it isn't forgotten and so the architecture leaves room for it (two perception modes behind one scene interface). Build after the Flutter-side findings (1, 2, 5) are solid.

---

---

# FINDING 8 — The instruction layer: the agent must operate like a human using a phone (HIGH LEVERAGE — possibly the biggest single lever on results)

This is not a bug. It is the single most under-built part of the system, and Run 1 shows it cost as much as the overlay bug did. The overlay blindness made the agent blind; the *instruction layer* made it respond to that blindness **un-humanly**, and that's what turned a small problem into a 12-minute thrash. Fix the sight in code (Finding 1); fix the *instincts* here.

## The core principle
**The phone, the app, the gestures — all of it was designed for a human, not a bot.** We have heavily invested in making Glint reproduce *human-style* interaction: real taps, real gestures, reading the screen the way a person sees it. If the instructions then tell the agent to think like it's calling a CLI or an API, we've built human-shaped tools and told the agent to use them like a robot. That mismatch is where it breaks.

The instruction doc's job is to install a **mental model**, not to list tools. The model: **"You are a person using this phone — with x-ray sight into *why* things work."**

## The frame: human mindset + developer x-ray vision
The agent is not *purely* a human — it can read the widget tree, knows keys, sees `hittable` vs `painted`. The right framing:
- **Behave with a human's mindset and patience.**
- **Use the deeper sight the tools give you to UNDERSTAND why something is happening — never to bypass the app.**
- X-ray vision is for *understanding*, not *cheating around* the interface.

This keeps the human model intact while still using Glint's real advantages.

## How a careful human operates (the behaviors to install)

1. **Look before acting.** A human reads the screen, finds the thing, then taps. Always `get_scene` and locate the target before tapping — never tap coordinates speculatively or hopefully.
2. **When an action seems to do nothing, RE-OBSERVE — never escalate.** A human whose tap did nothing looks again: is there a dialog in the way? did the screen actually change? am I tapping the right thing? They do **not** rewrite the app. Re-read the scene first, always.
3. **Understand waiting.** A human knows a screen takes a moment, a spinner means wait, an animation needs to finish. Patience is a first-class behavior. Observe that something is loading and wait — don't hammer.
4. **Read context, not just controls.** A human knows "I'm on the registration screen, I've filled my name, next is date of birth." Maintain that narrative sense of where you are in the flow — it keeps you goal-directed instead of flailing.
5. **Recover gracefully and BOUNDED.** Stuck on a step, a person tries the obvious alternative once or twice, then steps back and reconsiders the whole approach. They do **not** try fifteen increasingly desperate things. If a couple of human-reasonable attempts fail: stop, re-read what's actually true about the screen, reassess. Do not spiral.

## Anti-patterns — explicitly forbid these (Run 1 did all of them)
> **Do NOT** reach for `flutter driver`, `simctl`, `adb` direct, AppleScript, or **editing the app's source code** to accomplish a UI task.
> You are a **user**, not a developer debugging the app.
> If the UI isn't doing what you expect, the answer is to **look more carefully**, not to go around the app.

In Run 1 the agent, on a failed tap, escalated through exactly these — flutter driver → simctl → AppleScript → editing `InkWell` to `GestureDetector` → `HitTestBehavior.opaque` → hot restarts. A human has none of these instincts. This one instruction block would have prevented most of the 12-minute thrash.

## THE FEEDBACK LAYER — the most important part of this doc
**The entire app/interaction model is built around feedback when performing actions.** A human's whole loop is: act → perceive the result → decide the next move. Perception of the result *is* the loop. If the agent can't reliably perceive what its action did, it is operating blind, and everything downstream collapses into guessing. Run 1 is the proof: the agent acted, couldn't perceive the result (overlay blindness), and guessed for 12 minutes.

So feedback gets the heaviest emphasis. Principles:

1. **Every action must answer "what did that do?" — immediately and truthfully.** After a tap/type/scroll, the agent must know: did the screen change? did a new surface appear (dialog, route, overlay, native)? did focus move? or did *nothing* happen? This should come back *with the action* (see Finding 5: return what changed / scene-diff), not require a separate 3-call dance.
2. **"Nothing happened" is itself critical feedback — and must be unambiguous.** The worst state is an action that silently does nothing while *looking* like it succeeded (Run 1: `ok:true, hittable:true`, but `onTap` never fired). The feedback must distinguish "the event was delivered to your intended target and it responded" from "a tap landed somewhere hittable but your target didn't react." Conflating these is what made the agent think it was succeeding while failing.
3. **Feedback must explain, not just report.** A failure that says "not found" sends the agent guessing. A failure that says "not found — present in tree but inside an overlay you may not be reading / off-screen below / present but not hittable (barrier above it)" tells the agent its exact next move. **Diagnostic feedback is the difference between recovery and thrash.**
4. **Feedback mirrors human senses.** A human gets sight (the screen), and a sense of "that did/didn't respond" (the button depressed, the page moved). Glint's feedback should give both: the new scene (sight) AND a clear signal the action registered with its target (the tactile sense). The human phone experience has both channels; so must the agent's.
5. **Match feedback granularity to the `ls` tiered principle.** Default feedback is shallow and cheap ("tapped Login → navigated to /home"). When the agent needs more, it can drill ("describe what changed in detail"). Don't dump; let the agent pull depth on demand. Feedback is tiered like everything else.
6. **The feedback IS the product's foundation.** Restating because it's the thesis: we designed the whole tool around human-style acting, and human acting only works because of human perceiving. The perception/feedback half is not secondary to the action half — it is the half that makes the action half usable. Invest here first and most.

## Doc structure recommendation
- **Length: detailed — but detailed about BEHAVIOR and MINDSET, not tool syntax.** The tool reference (params, return shapes) is terse and *separate*. This doc is the *philosophy of operating*.
- **Order:** lead with the human-mindset frame → the feedback layer (heaviest section) → the behaviors → the anti-patterns. Mindset and feedback first because they're what install the right instincts.
- **Tone:** speak to the agent as a person learning to use a phone well, with the bonus of x-ray sight to understand the why.

## Why this is high leverage
Run 1 did **not** fail purely on the overlay bug. It failed on the overlay bug **plus** the agent responding to it un-humanly (escalating mechanically instead of re-observing). Fix the sight in code (Finding 1), fix the instincts in instructions (Finding 8), and the thrash largely disappears. This instruction layer may move Run 2 results more than several of the code fixes — because the code fixes give the agent better senses, but the instructions are what make it *use* those senses like a human instead of a flailing bot.

---

## Fix priority — Sprint 1 (consolidated)

Grouped into two tracks that run together: **code (better senses)** and **instructions (human instincts)**. Run 1 proved you need both — the bug blinded the agent, the missing instructions made it flail. Fix one without the other and Run 2 still struggles.

**Track A — Code (give the agent better senses)**
1. **Overlay-aware `get_scene`** (Finding 1) — root cause; traverse from root incl. Overlay stack; mark barrier'd screen as painted-but-not-hittable. Unlocks the most.
2. **Feedback on every action: "what changed?" return + scene-diff** (Findings 5 + 8) — the feedback layer is the foundation; collapses the multi-call detection dance, removes the "looked like success but did nothing" ambiguity.
3. **Diagnostic failure messages + `describe` drill-down** (Finding 5) — failures must say *why* (not-in-tree / in-overlay / off-screen / not-hittable) so the agent recovers instead of guessing.
4. **Tap gesture fidelity + distinguish "hittable point" from "target received event"** (Finding 2) — partly resolved by #1; finish with the real-vs-injected gesture diff.
5. **Survive hot reload/restart** (Finding 6) — auto-reconnect; matters more once editing-in-loop.
6. **Resident tool set / less ToolSearch churn** (Finding 4).
7. **Cold-start handling + revisit true latency** (Finding 3) — largely downstream of the above.

**Track B — Instructions (make it use those senses like a human)**
8. **Write the instruction layer** (Finding 8) — human-mindset + x-ray-sight frame; feedback-first; the behaviors; the explicit anti-pattern block (no flutter driver / simctl / AppleScript / source-editing for UI tasks). May move Run 2 more than several code fixes.

**Deferred (post-sprint):**
- Native-surface perception via signal fusion (Finding 7) — only once the Flutter-side senses + instructions are solid.

## Process notes for next run
- **Confirm thinking is actually ON.** This run's thinking blocks were empty even on Sonnet — check the raw JSONL `"thinking"` fields. If empty there, thinking wasn't enabled; we lost the reasoning and diagnosed from short narration only. Real thinking would sharpen the tap-not-firing diagnosis especially.
- **Pre-warm app + attach before the timed portion** so the test measures the flow, not the ~13-min boot.
- **Keep "no screenshots"** — it correctly forced the render-tree path and exposed the overlay gap.

## Open questions
- Tap-not-firing: how much is the modal barrier (Finding 1) vs genuine gesture incompleteness (Finding 2)? Isolate by testing a tap on a known non-overlay button with no modal present.
- Was the early "tap registered but didn't navigate" on login the same overlay/barrier issue, or the modal intercepting, or a third thing?
- Does the injected tap differ from a real finger in the HID/pointer signature? Run the real-vs-injected diff harness.
