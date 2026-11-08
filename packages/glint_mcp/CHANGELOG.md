# Changelog

All notable changes to glint are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, where before 1.0 a minor bump may break things.

## [Unreleased]

### Changed

- The changelog is one line per change.

## [0.7.0] - 2026-11-08

### Added

- `media op:speech` scripts what the user says to an app that listens on an iOS simulator, with partial and final results (and a mic feed on Android). (#256)
- `media op:broadcast` runs an app's ReplayKit broadcast upload extension on an iOS simulator. (#227)
- `media op:camera` gives iOS simulators a front and back camera fed by an image, video, test card or the Mac webcam. (#226, #278)
- `image_picker`'s camera works on iOS simulators while a `media op:camera` feed is set. (#278)
- `media op:event kind:call` simulates an incoming call on iOS simulators, and `kind:callkit` stands in for CallKit. (#228, #256)
- `hot_reload` reports the errors the reload caused, in `data.errors`. (#302)
- `get_scene` flags layout errors thrown since the last read and warns with `emptyViewport` when a scrollable shows nothing. (#304)
- `watch conditions:[{errors:true}]` fires on each new distinct app error. (#303)
- `attach observe:true` attaches read-only; acting tools are refused with a clear errorKind. (#303)
- `explore` keeps a map of the screens and gestures seen per app and answers what is left to try. (#211)
- `watch allApps:true` is one alert stream across every attached app, independent of the app's logging. (#310)
- `watch conditions:[{lint:true}]` checks the live layout for overflow, keyboard, insets, tap target, clipped text and line-count problems. (#311)
- Local usage events carry the version, platform and device kind needed to diagnose a slow or failed call, and the usage log is archived instead of cut.

### Changed

- `report_issue` no longer names the app or the device; both become `<app>` and `<device>`. (#320)
- The server instructions tell agents to hand a step to a person with `watch` (PIN, 2FA, sign-in, real-money confirms). (#298)
- `wait_for` says which way it is waiting and what it matched, and its `timeoutMs` is capped at 60 s. (#299)
- `scroll_to_find` is cheaper per scroll, capped at 50 `maxScrolls`, and stops when the list really ends. (#327, #331)
- `batch` has a time budget (`budgetMs`) and always answers, with `errorKind: budgetExceeded` when it runs out. (#327)
- Guessed argument names (`fromX`, `amount` and similar) are accepted, with a warning naming the right one. (#327)

### Fixed

- `scroll_to_find` no longer flings past its target. (#331)
- `scroll_to_find` waits for the next page of a paginated list, and an iOS runner built by another glint version is no longer thrown away. (#330)
- A native screen with only a toolbar is no longer called an alert in `get_scene`.
- Attach and the iOS native helpers no longer hang silently; builds and helper calls time out with `toolTimeout`. (#328)
- glint no longer leaves helper processes behind, and old helper binaries and runner builds are pruned (`glint --prune-cache --dry-run` lists them).
- No tool call blocks forever or silently any more; every subprocess has a cap and a reason when it expires.
- `media op:pick` no longer says a photo was chosen when the picker is still open or unreadable. (#255)
- `attach launch:"<app id>"` brings an app already running on an iOS simulator to the front. (#300)
- A backgrounded app on the iOS simulator can be reopened from its home screen icon with `tap text:` or `tap x,y`. (#300)
- `tap text:` on a surface glint cannot read says why and points to `attach launch:`. (#300)
- A failing lifecycle check no longer reports the app as `paused`. (#300)
- `attach` no longer hangs behind a system prompt; it names the surface and its choices.
- A tap or type no longer waits tens of seconds on a read after it was delivered, or on an app that cannot take it.
- A setState that lands 2 to 4 s after a tap, or behind a looping animation, is no longer reported as `changed: false`.

## [0.6.0] - 2026-10-31

### Added

- System alerts over the app are seen by default on the iOS simulator: `attach` starts the native reader in the background, and the reply says `ready`, `starting`, `unavailable` or `off`. (#249)
- `watch` registers conditions (text, `glintId` state, route, overlay, log regex), returns at once and wakes the agent when one matches. (#262)
- `report_issue` takes `expected`, `actual`, `timeline`, `failureSeqs`, `suspectedCause`, `suggestedFix`, `workaround`, `impact` and `repro`, and lists `missingSections`. (#261)
- `wait_for_settle` takes `timeoutMs` as an alias for `ceilingMs`. (#274)
- The server instructions suggest handing long UI-driving runs to a subagent. (#276)
- `app_logs` can search with `contains:` and `match:` (regex). (#270)
- `device op:screenshot` works on Android, in device mode and Flutter mode. (#267)
- `session op:detach` drops an app or device and frees its claim, and `session op:status` notices a device that is gone. (#266)
- Log breakpoints: `breakpoint op:set pattern:` pauses the app on a matching log line, screenshots it and holds it until `op:resume`.
- `location op:route maxSpeedKmh:` varies speed like a driver, braking for bends and stopping at the end.

### Fixed

- `notifications` says when the app is not allowed to show them instead of reporting a banner that iOS dropped. (#269)
- Device mode on the iOS simulator reads and taps native alerts and screens such as the photo picker. (#278)
- `hardware_button back` closes a sheet or dialog on iOS. (#274)
- A no-change action warns when another glint process is driving the same device. (#260)
- `attach device:<AVD>` stops after 60 s when adb keeps the emulator offline, and says why. (#268)
- `type focus:` and `tap` reach an input hidden behind a visible control. (#273)
- Custom checkboxes and chips that only change how they look now count as a change and show their state. (#275)
- `scroll_to_find` swipes the scrollable the target lives in and stops when a swipe moves something else. (#271)
- Several agents sharing one glint no longer land on each other's apps. (#279)
- `app_logs` keeps its entries when the same app is attached again. (#277)
- On the iOS simulator, a system alert over the app no longer swallows taps, and a busy app is no longer called new. (#265, #258, #257, #255)
- `attach launch:` names the real reason when `flutter run` fails.
- Coordinates are logical points everywhere, and a point off the screen is refused with the value to use. (#272)
- `swipe` and `drag` report a scroll, and `scroll_to_find` no longer counts a row hidden under a pinned header. (#259)

## [0.5.0] - 2026-10-19

### Added

- `record touches:true` also writes `video-touches.mp4` with every touch glint sent drawn on it.
- Touches are drawn system-wide on an Android emulator when `showTouches` is on.
- `attach showTouches:true` (or `config op:set key:showTouches`) draws each touch inside the app. Debug builds only.
- `attach device:"<AVD name>" camera:"webcam"` boots an Android emulator with the Mac's camera as its front camera. (#225)
- `location op:route polylineId:` plays the route a Google map in the app draws. (#229)
- `attach` tells the agent once per session when a newer glint is on pub.dev; `GLINT_NO_UPDATE_CHECK=true` turns it off.

### Fixed

- On Android, a system dialog over a running app no longer swallows glint's in-app touches.
- `scroll_to_find` finds plain text in plain sight, and reports `notHittable` when something covers it.
- Form fields with different labels no longer fold together and hide validation errors. (#234)
- Typing on Android is fast again: it defaults to `input:app`, and `input:device` keeps the old path. (#219)
- A tap that starts a network request is no longer reported as `changed: false`.
- `tap text:"Allow"` no longer fails as `internal` when a system dialog is up before the app's first frame. (#233)
- Buttons from a design-system package now have a label and can be tapped by text. (#232)
- Controls faded out with `AnimatedOpacity`, `FadeTransition` or `IgnorePointer` are no longer listed or tapped as visible. (#220)
- A GPX route on the iOS simulator no longer falls behind and arrives on time. (#230)

## [0.4.2] - 2026-10-15

### Changed

- Added an example, analysis options and `dart format` so the package scores fully on pub.dev.

### Added

- glint installs from pub.dev with `dart pub global activate glint_mcp`, and each release tag publishes there.

### Fixed

- The phone OCR reader and the XCTest runner are found in a pub.dev install.

## [0.4.1] - 2026-10-15

### Fixed

- Typing on a physical iPhone with `input:device` no longer freezes the app on characters the hardware keyboard cannot type.
- The local network prompt after `attach launch:` on a phone is answered even when it appears late.
- `device op:status` says the phone needs its passcode when it is locked.
- A physical iPhone on Wi-Fi only keeps screenshots and `device op:status`; touches fail with a clear step to plug it in.
- The covered-app warning says to tap by text, not by x,y.

## [0.4.0] - 2026-10-15

### Added

- `pinch` tool: two fingers around a node or x,y, spreading (`scale:2`) or closing (`scale:0.5`), with real multi-touch on a physical iPhone.
- `swipe edge:` makes system gestures from a screen edge on a physical iPhone (`left`, `bottom`, `bottomHold`, `topLeft`, `topRight`).
- `type` handles accents, emoji and other scripts on a phone's device path.
- `device op:openurl` opens a URL or deep link on a physical iPhone, and `kill_app` stops an app there.
- `device op:network` sets a network condition on a physical iPhone and clears it on detach or exit.
- `hardware_button` on a physical iPhone: `back` is a real edge swipe, `appSwitcher` a double Home press, and `unlock` wakes it (`notOnThisDevice` when a passcode is set).
- `sensors op:set orientation:` turns a physical iPhone.
- `record`, `device op:status`, `sensors op:read` and `app_logs native:true` work on a physical iPhone.
- `attach launch:"<project>"` builds and runs on a physical iPhone, picks the signing team without file edits (`signingTeam:`, `signingFailed` with `data.teams`) and answers the local network prompt.
- `attach` answers `deviceBusy` at once when another `flutter run` already debugs the phone.
- A device claim with no input for 15 minutes reads as idle, so `attach` drives the device and says so.
- Faster screenshots on a physical iPhone, and `attach` warms the helper in the background.
- Actions reply about twice as fast: input, settle and lifecycle now run inside the app.

### Changed

- The iOS simulator defaults to `input:auto`; `attach input:"device"` keeps the old behaviour.
- `attach input:` (`app`, `device`, `auto`) picks where gestures go on every device; `iosInput` is now only the simulator's real-touch transport.
- Every action reply reports delivery in `data.input` (`{path, reason?, ms}`) and prints `· via app` or `· via device (systemSurface)`.
- **Breaking:** attach's tested-setup block moved from `data.input` to `data.setup`, and the route is in `data.inputRoute`; read those instead.
- **Breaking:** device failures have their own errorKinds: `deviceNotConnected`, `developerImageMissing`, `deviceBusy` and `inputPartial` replace `unsupportedBackendAction`.
- The iPhone helper is 43% smaller.

### Fixed

- An action that opened a system surface (Control Center, a permission prompt) is no longer reported as `nothing changed`.
- `tap` and `long_press` take `text:` or `glintId:` on a native surface too, with `targetNotFound` listing what the surface shows.
- Native surfaces come back as `data.surface` (kind, title, choices) in `get_scene` and action replies.
- What a device cannot do is declared once: tools refuse with `errorKind: notOnThisDevice` and `data.instead`, and `attach` lists it.

## [0.3.0] - 2026-10-15

### Added

- glint drives a physical iPhone, inside the Flutter app by default or with real touches through Device Hub (`glint-devicehid`); `iosInput:auto|dtuhid|flutter` picks the path and each reply says which in `via`.
- `attach mode:device` works on a paired iPhone with no Flutter app.
- `get_scene` reads native surfaces over the app on a physical iPhone, and action replies report `nativeSurface` and `nativeDismissed`.
- `notifications` on the iOS simulator presses a notification's buttons and opens entries that are only in the Notification Center.
- `media op:mic` feeds a tone, speech or an audio file into the microphone of apps on an Android device. (#137)
- `sensors` tool: `op:read` gives orientation and Android sensor samples, `op:set orientation:` drives it, `op:script` runs a motion sequence. (#162)
- `notifications` tool: `op:list`, `tap`, `action`, `clear`, `send` (iOS push payloads) and `answer` for the permission prompt, on iOS simulators and Android. (#168)
- `device op:screenshot` takes `glintId:`, `region:`, `apps:`, `afterMs` and `waitFor`, and works on an attached Android app. (#167)
- A `batch` step may name its own `app:`, so one batch drives several devices. (#165)
- `wait_for` tool waits for a text or `glintId` to appear or, with `gone:true`, disappear, on any attached app. (#165)
- `tap`, `long_press` and `resolve` take `text:`, with dialogs searched first. (#169)
- `glintId` is accepted by `type` (`focus`) and `scroll_to_find` (`targetGlintId`), `key key:back` presses system back, and `scroll_to_find tap:true` finds and taps in one call. (#169)
- `device op:privacy` works on Android. (#166)
- `map` tool drives a Google map: `op:read`, `tap marker:`, `pan`, `zoom`. (#148)
- Location replies say whether the app is in the foreground (`appInForeground`) and can get location in the background (`backgroundLocation`). (#148)
- `location op:wait` blocks until a route arrives, reaches a progress or waypoint, or the position is near a point. (#148)
- `get_scene` reads Google maps: camera, markers, routes and areas. (#148)
- `location op:permission` sets the app's location access without a prompt. (#148)
- `location` tool simulates GPS on iOS simulators, Android emulators and a paired iPhone: `op:set`, `op:route` with points, GPX, KML or a polyline. (#148)
- `attach device:"<AVD name>"` boots an Android virtual device when nothing runs it; `attach dryRun:true` lists the AVDs not running. (#151)
- `media op:camera` sets what an Android emulator's cameras see. (#137)
- `media op:event` sends device events (`rotate`, `light` and more) to an Android emulator. (#137)
- `media op:listen` records what an Android emulator plays as a WAV. (#137)
- `media op:permission` sets camera, microphone or photos access (`grant`, `deny`, `reset`, `limited`). (#137)
- `media op:pick` chooses a photo or video in the open system photo picker. (#137)
- `attach` finds a paired, connected iPhone and matches its app. (#136)
- `media` tool for the media loop of an app: `op:seed` puts a photo or video in the gallery, plus `inspect` and more, on iOS simulators and Android emulators. (#137)
- `attach launch:` also takes an installed app id and reopens that debug build in seconds without a rebuild. (#103)
- `hot_reload` reloads or, with `restart:true`, restarts the attached app. (#118)
- Apps and devices are owned by the session that attached them; `kill_app appId:` and `shutdown_sim` refuse anything it never attached. (#118)
- Android input goes through glint's own resident server, so taps, swipes and text of any script are fast and reliable.
- A second iOS backend: glint's XCUITest runner (`attach iosBackend:xctest`).
- Device claims: `attach` will not auto-pick a device another live session drives and refuses with `errorKind: deviceClaimed`. (#102)

### Changed

- `attach device:` no longer calls a simulator with one Flutter app ambiguous. (#135)
- The back, close and drawer buttons an app bar adds by itself now show in the scene and are tappable.
- Apps on go_router (and other `Router` navigation) report their real `route` and `routeChanged`.
- **Breaking:** a `#hash` id no longer changes when something near it changes; ids with a `#hash` change once with this release, so re-read them.
- A tap that only changed how something looks now reports `contentChanged`.
- Buttons say what they would do: `ListTile` taps are tappable, handler-less buttons are marked, and icon buttons take their tooltip as label.
- `TabBar` tabs are named and the current one is `[selected]`.
- State-management builders no longer show as empty `unknown` lines.
- Cupertino page scaffolds count as pages, so their screens are no longer reported as dialogs.
- Pages covered by another route no longer stay in the scene inside shell routes and nested navigators.
- A local iOS bridge build no longer silently wins over a newer downloaded one. (#161)
- After a hot restart, glint no longer binds to the wrong isolate in apps with push or background-task plugins. (#170, #121)
- Hidden tabs of an `IndexedStack` are no longer read as on screen on Flutter 3.47 and later.
- Navigation bars show as a `tabs` container of tappable buttons named by their labels.
- A sheet or dialog opened from a page in a nested navigator is no longer missed. (#171)
- `get_scene` keeps up to 80 characters of on-screen text, and `get_scene glintId:` shows a node's text whole.
- On Android, `attach` no longer warns that the glint Android server cannot be downloaded.
- `attach` no longer offers a saved app whose project folder was deleted.
- Segmented controls are visible and tappable, and the selected segment reads `[selected]`.
- A route on the Android emulator no longer stops partway while reporting progress.
- Markers, routes and areas under a map no longer fold into "… N more like it".
- `media op:camera` finds an emulator launched from a sandboxed shell. (#151)
- `attach` with a different `iosBackend` or `androidInput` no longer silently drops the backend. (#150)
- `long_press` holds for 800 ms by default instead of 500 ms. (#112)
- An unplugged physical Android phone is reported as disconnected, not as a closed emulator. (#120)
- A tap on a native surface that did not react no longer reports `changeCategory: nativeSurface`. (#115, #119)
- `app_logs native:true` lists the app's native crashes since attach, and a crash reports `connectionLost` with the reason.
- Tool definitions are 12% shorter, with no argument or behaviour change.

### Fixed

- `media op:inspect` finds a test card inside black bars, and still images count as photos.
- On Android, attaching while a native surface covers the app no longer loses track of the app.
- `attach device:` no longer takes a claim away from another live glint session. (#139)
- When `attach device:X` cannot settle on one app, only apps on X are offered. (#135)
- `type` no longer reports success when a repeated key corrupted the field text. (#75)
- Native UI an iOS app presents in its own process (photo picker, text edit menu) is now seen, and closing it reports `nativeDismissed`. (#80)
- `type clear:true` clears text after the cursor too.
- On Android, the first keys typed into a field just switched to are no longer lost.
- `type` warns when the typed text did not reach the field.
- A glintId keeps resolving when its `_in_<parent>` part or `#hash` changes between reads. (#117)
- A bottom sheet or dialog that contains a text field is no longer left out of `get_scene`. (#111)
- On iOS (Indigo input), a key no longer stays pressed for seconds on a loaded machine. (#75)
- iOS taps are a short held contact, so they are no longer dropped. (#113)
- `attach launch:` refuses a folder that is not a Flutter app at once instead of waiting out the timeout. (#103)
- When the app on the named `device` is gone, `attach` leads with relaunching on that device. (#103)
- A photo set as a `DecorationImage` on a `Container`, `DecoratedBox` or `Ink` now shows in `get_scene`. (#79)

## [0.2.0] - 2026-09-27

### Added

- iOS input goes over `dtuhidd` on Xcode 27, so simulator taps, keys and buttons are no longer dropped after it starts. (#74)
- Xcode 27 support: every bridge action is verified there.
- iOS `attach` reports the toolchain: Xcode version, bridge source and protocol.
- Each release ships a universal `glint-iossim-macos` bridge that glint downloads on the first iOS attach; `GLINT_NO_BRIDGE_DOWNLOAD=true` turns that off and `GLINT_IOS_BRIDGE` points at your own.
- `attach` reports the input setup it is on and whether glint has verified it, with known issues when it is untested.
- `hittable` comes from Flutter's own hit test (`hitTest: "real"`), a miss names what would take the touch (`hitBy`), and a tap that would land elsewhere is refused with `notHittable`. (#77)
- A glintId that is really a visible label gets a next step naming the id to use. (#86)
- `scroll` reports a `reason` when nothing moved: `atEnd`, `atStart`, `notScrollable` or `blocked`. (#84)
- Selected chips and `Semantics` toggles show `[selected]`, `[on]` and `[off]`, and selection counts as a change. (#78)
- Images name what they show, and a childless `CircleAvatar` or `Ink` is an image. (#79)
- Action replies write the change report into their text (`· routeChanged`, `· nothing changed`). (#78)
- Images sent to the model are shrunk and re-encoded by default (`screenshotMaxSize`, `screenshotFormat`, `screenshotQuality` in `config`), and say how pixels map to `tap x,y`. (#89)
- When native UI takes over, `get_scene` and action replies attach the screenshot as an image, and `record inline:true` attaches frames. (#85)
- On Android, a system window in front of the app is detected and its elements are listed with tap coordinates. (#80)

### Changed

- A log value the VM cuts now says how much was cut.
- Usage rollups come from glint_core, and `telemetry op:"report"` shows `avgEstimatedTokens`, `degraded` counts and error kinds by frequency.
- `attach` suggests `glint-network__network_attach` for HTTP monitoring.
- **Breaking:** on an Xcode major glint has not verified, bridge actions are refused with `errorKind: unsupportedToolchain`; set `GLINT_ALLOW_UNTESTED_XCODE=true` to run them.

### Fixed

- `telemetry op:"audit_verify"` reports entries written by two servers at once as a fork, not a broken chain.
- `report_issue` masks `access_token=` and `refresh_token=` values too.
- A target clipped by its scroll view is now off-viewport, so taps no longer land on whatever covers it. (#77)
- `scroll` swipes inside the visible part of the scrollable, above the keyboard. (#84)
- Folded rows keep all their texts, so values on review and settings screens no longer vanish. (#82)
- Items in lazily built lists and wheels keep a stable id after a scroll. (#81)
- An empty Android recording says whether it failed to decode or another tool holds the screen. (#95)
- A spinner inside a button now counts as loading, and `wait_for_settle` no longer calls an animating screen settled. (#83)
- A page route's own barrier no longer reads as an open overlay. (#86)
- Error replies include the line with the reason, and a failed geometry read is retried once. (#87)
- iOS taps, keys and button presses are no longer lost or repeated, and typing `hello glint` no longer gives `hello. glint`.

## [0.1.0] - 2026-09-25

First tagged release. glint lets an AI agent drive a running Flutter app on an iOS Simulator or Android emulator, with nothing added to the app.

### Added

- `get_scene` reads the screen as a compact scene built from Flutter's own widget tree, with ids an agent can act on and dialogs above the page they cover.
- Actions work like a person's (`tap`, `long_press`, `type`, `key`, `scroll`, `scroll_to_find`, `swipe`, `drag`, `hardware_button`, `batch`) and report how the screen changed.
- `attach` with no arguments finds the running app and its device, and keeps working across a hot restart.
- Device mode drives a simulator or emulator without a Flutter app, through screenshots and coordinates.
- App logs, screen recording, Face ID and Touch ID on the iOS Simulator, and lock and unlock.
- Debug and profile builds only; see "Limits today" in the README.

### Security

- Password fields show only their length, and typed text never reaches the action log or an issue report.
- `report_issue` drafts first and files only with the user's OK, redacting paths, tokens, keys and passwords.
- Android typing sends text as one quoted argument, so shell characters are typed literally.
- Telemetry is off unless the user sets `GLINT_TELEMETRY=on`.
