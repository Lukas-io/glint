# Changelog

All notable changes to glint are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, where before 1.0 a minor bump may break things.

## [Unreleased]

### Fixed

- A glintId stopped resolving when its `_in_<parent>` part or `#hash` changed between reads, which happens when another node with the same name appears or leaves (a text field read as `text_field_in_qc_glass_card` before focus and `text_field` after). An id that no longer exists now resolves to the one node of the same name built at the same source location as the id's earlier holder, so `focus:` and taps taken from an earlier scene keep working. A stale id never resolves to a different widget (#117).
- A bottom sheet or dialog that contains a text field was left out of `get_scene` (only the page below showed, with no overlay marker), because any overlay holding a `TextField` was taken for the cursor handles and copy/paste toolbar. Only an overlay with no editable field counts as that chrome now. Fields inside sheets and dialogs also get their label, value and error read, so typing into them reports a change (#111).

### Fixed

- iOS (Indigo input): every key and touch event waited up to 2 s for the simulator's acknowledgement before the next was sent, so on a loaded machine a key stayed pressed for seconds and repeated (`hello glint` typed as `hello. glint`), and typing 11 characters took up to 80 s. Presses now go out at once and each release waits for everything still unacknowledged, so a key or finger is held only as long as intended (#75).
- iOS taps are a short held contact (down, a move frame at the same point, up after about 100 ms) instead of a bare 50 ms down/up, the same shape as the zero-length swipe and 120 ms long press that landed reliably where plain taps were dropped (#113).

### Changed

- `long_press` holds for 800 ms by default instead of 500 ms. 500 ms equals Flutter's long-press threshold, so about half of default long presses ended just before Flutter recognised them (#112).
- An unplugged physical Android phone was reported as a closed emulator, with a next step to boot it. It is now reported as disconnected, with "ask the user to reconnect the phone, then attach" (#120).
- A tap on a native surface (a system alert, permission dialog or another app) reported `changeCategory: nativeSurface`, which reads as success, even when the surface did not react. glint now compares the screen before and after (giving native animations time to finish): unchanged means `changed:false`, `changeCategory: nothing` and a warning to check the coordinates or ask the user to tap; changed means `changed:true` (#115, #119).

### Changed

- Tool definitions are 12% shorter (32.6k to 28.5k characters, about 1,000 fewer tokens on every turn). The `app` argument and the gesture arguments shared by tap, long_press, swipe, drag, scroll and type now use one tight wording each, and the ten longest tool descriptions no longer repeat what their arguments and the instructions already say. No argument or behaviour changed.

### Fixed

- `attach launch:` accepted any folder with a `pubspec.yaml`, the Flutter SDK included, and then waited out the whole launch timeout (180 s) before failing. It now refuses at once unless the folder is a Flutter app (a `flutter` SDK dependency and `lib/main.dart`), names what is missing, and lists apps glint launched before. A named Android device (`emulator-…` or one discovery lists) is launched as Android instead of going through `simctl boot` (#103).
- When the app on the `device` you named is gone and another device has one, attach no longer suggests omitting `device` (which moves you onto the other device). It leads with relaunching on your device when glint launched an app there before (#103).

## [0.2.0] - 2026-09-27

### Added

- iOS input over `dtuhidd` on Xcode 27. Once anything starts dtuhidd on a simulator boot, the simulator drops taps, keys and buttons sent the old way (Indigo) until it reboots; that was #74. The bridge now sends touch, keys, home and lock through dtuhidd when CoreSimulator ships it, falls back to Indigo when it does not answer, and says which it used. `attach iosInput:indigo|dtuhid` overrides the choice, and the attach `input:` line and the tested setups name the transport. Bridge protocol 2.
- Xcode 27 support. Xcode 27 moved SimulatorKit to `Contents/SharedFrameworks`; the bridge now loads it from there, and every bridge action (tap, tap sequences, long press, swipe, typing, keys, lock, unlock, home, back, recording) is verified on Xcode 27.0.
- iOS `attach` checks the toolchain and reports it under `toolchain`: the Xcode version, where the bridge came from, and its protocol number.
- Each release attaches a universal (Apple Silicon and Intel) `glint-iossim-macos` bridge with a sha256. glint downloads it on the first iOS attach when no local build exists, into `~/.glint/bin`. `GLINT_NO_BRIDGE_DOWNLOAD=true` turns that off.
- `GLINT_IOS_BRIDGE` points glint at a bridge binary.
- The bridge answers `glint-iossim version`, and glint warns when a local build speaks a different protocol.
- `attach` reports the input setup it is on (iOS runtime, Xcode, macOS and backend, or the Android API level) and whether glint has verified it, with known issues and the closest proven setup when it is untested. The list lives in `tested_matrix.dart`.
- `hittable` comes from Flutter's own hit test at the target's centre (`hitTest: "real"`); when that can't run it falls back to the old check and says `hitTest: "approximate"`. A miss names what would take the touch (`hitBy`), and a tap that would land on another widget is refused by default with `errorKind: notHittable` (#77).
- A glintId that is really a visible label ("Create account") gets a next step naming the id to use (#86).
- `scroll` reports `reason` when nothing moved: `atEnd`, `atStart`, `notScrollable` or `blocked` (#84).
- Buttons show `[selected]` when the widget (chips) or its `Semantics` wrapper says so, and a `Semantics` `checked`/`toggled` fills `[on]`/`[off]` for custom toggles. Selection counts as a change, so tapping a pill no longer reports `changed:false` (#78).
- Images name what they show (`- image profile.jpg (loaded)`), read from the image provider; a childless `CircleAvatar` or `Ink` is an image (#79).
- Action replies write the change report into their text (`· routeChanged`, `· nothing changed`) for clients that only read text (#78).
- Images sent to the model are shrunk and re-encoded first: by default JPEG at quality 75 with the longest side at 1024 px (`screenshotMaxSize`, `screenshotFormat`, `screenshotQuality` in `config`; `maxSize` per `device op:screenshot`). An iPhone 17 screenshot goes from a 1206×2622 PNG (about 2,900 tokens) to a 471×1024 JPEG (about 640). Every inline image says how its pixels map to `tap x,y` (#89).
- When native UI takes over, `get_scene` and the action reply attach the screenshot as an image instead of only a file path, and `record inline:true` attaches up to 4 frames at 512 px, so agents without a file tool can see them (#85).
- On Android, a system window in front of the app (the photo picker, another app) is detected from the window manager: the action reply says `changeCategory: nativeSurface` and names it, and `get_scene` lists the window's elements from `uiautomator dump` with `@ x,y` tap coordinates. When the dump fails it says why, for example when another automation tool holds the accessibility connection (#80).

### Fixed

- `telemetry op:"audit_verify"` reports entries written by two servers at once as a fork, not a broken chain, and new entries can't fork any more.
- `report_issue` now masks `access_token=` and `refresh_token=` values too. Redaction moved to glint_core, which uses the stricter of the two copies the packages had.
- A target clipped by its scroll view counted as painted and on screen, so taps landed on whatever covered it (on Android, the button bar below a form). It is now off-viewport, and the refusal says it is clipped or under the keyboard (#77).
- `scroll` swiped around the centre of the screen, which with the keyboard up is often the keyboard. It now swipes inside the visible part of the scrollable, above the keyboard (#84).
- Folded rows kept only their first text, so values on review and settings screens vanished (a row said "Distance" and hid "Up to 50 mi"). A folded item now keeps all its texts, and the trailer points at each run's parent to expand it (#82).
- Items in lazily built lists and wheels took their id from their slot, so after a scroll the same id meant a different item. Under ListView, GridView, ListWheelScrollView, CupertinoPicker and PageView, the id now follows the item's text; wheels and pickers also show as scrollable (#81).
- An empty Android recording said only "no frames captured". `record` now tells an empty recording from one that failed to decode, and on Android names the other tool's device server holding the screen (for example mobile-mcp's DeviceServer or scrcpy); the Android native reader does the same when `uiautomator` is killed (#95).
- A spinner inside a button didn't count as loading, so replies said `state: loaded` while the screen was still working. Loading is now read from every widget on the page. `wait_for_settle` no longer calls an animating screen settled while a spinner shows, and says which signal settled it (#83).
- A page route's own barrier and empty text-field chrome were read as open overlays, so errors claimed "a non-modal overlay is active" on plain screens (#86).
- Error replies showed only the first line of a VM error, which is often just "Unhandled exception:". They now include the line with the reason, and a failed geometry read is retried once and says what to do next (#87).
- iOS taps, keys and button presses were sometimes lost, and a key could repeat (typing `hello glint` gave `hello. glint`). The bridge sent each input message without waiting for the simulator to take it and could exit before the last one was delivered; it now waits for each message to be acknowledged, and fails with a clear error if one isn't.

### Changed

- A log value the VM can't expand now says how much was cut (`… [cut by the VM at 128 of 4000 chars]`) instead of silently showing the preview.
- Usage rollups come from glint_core. `telemetry op:"report"` also shows `avgEstimatedTokens`, `degraded` counts, and error kinds sorted by frequency.
- `attach` suggests `glint-network__network_attach` for HTTP monitoring, the network toolset's new name.

- On an Xcode major glint has not been verified on, bridge actions are refused with the new `errorKind: unsupportedToolchain` and steps to fix it; `GLINT_ALLOW_UNTESTED_XCODE=true` lets them run. A missing bridge now fails the same way instead of with a raw process error.

## [0.1.0] - 2026-09-25

First tagged release. glint lets an AI agent drive a running Flutter app on an iOS Simulator or Android emulator, with nothing added to the app.

### What it does

- `get_scene` reads the screen as a compact scene built from Flutter's own widget tree over the Dart VM service, with ids an agent can act on, and shows dialogs and sheets above the page they cover.
- Actions work like a person's: `tap`, `long_press`, `type`, `key`, `scroll`, `scroll_to_find`, `swipe`, `drag`, `hardware_button` and `batch`. Each reports whether and how the screen changed.
- `attach` with no arguments finds the running app and its device, and keeps working across a hot restart.
- Device mode drives a simulator or emulator without a Flutter app, through screenshots and coordinates.
- Also: app logs, screen recording, Face ID and Touch ID enrolment and matching on the iOS Simulator, and lock and unlock.

### Security and privacy

- Password fields show only their length, and typed text never reaches the action log or an issue report.
- `report_issue` drafts first and files only with the user's OK; paths, tokens, keys and passwords are redacted.
- Android typing sends text as one quoted argument, so shell characters are typed literally.
- Telemetry is off unless the user sets `GLINT_TELEMETRY=on`; see `TELEMETRY.md`.

### Known limits

See "Limits today" in the README: debug and profile builds only, Xcode 26 for iOS, ASCII typing, no web or desktop yet.
