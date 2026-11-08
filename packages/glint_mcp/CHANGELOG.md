# Changelog

Versions follow semver; before 1.0 a minor bump may break things.

## [Unreleased]

## [0.7.1] - 2026-11-08

- Shortens the changelog to one row per change.

## [0.7.0] - 2026-11-08

- Adds `media op:speech`, `op:broadcast` and `kind:call` to iOS simulators. (#256, #227, #228)
- Adds `media op:camera` for iOS simulator cameras fed by image, video or webcam. (#226, #278)
- Adds `attach observe:true` and `watch` errors, lint and `allApps`. (#303, #310, #311)
- Adds `explore`, a map of the screens and gestures seen per app. (#211)
- Adds reload errors to `hot_reload` and layout errors to `get_scene`. (#302, #304)
- Changes `report_issue` to replace app and device names with `<app>` and `<device>`. (#320)
- Improves `wait_for`, `scroll_to_find` and `batch` with caps and clearer replies. (#299, #327)
- Fixes `scroll_to_find` flinging past targets and missing paginated lists. (#331, #330)
- Fixes `attach` hangs, leftover helper processes and wrong `media op:pick` results. (#328, #255)
- Fixes false `changed: false` replies and reopening a backgrounded iOS app. (#300)

## [0.6.0] - 2026-10-31

- Adds system alert reading on the iOS simulator by default. (#249)
- Adds `watch`, which wakes the agent on text, state, route, overlay or log matches. (#262)
- Adds `report_issue` fields for expected, actual, repro and more. (#261)
- Adds `app_logs` search, `session op:detach` and Android `device op:screenshot`. (#270, #266, #267)
- Adds log breakpoints with `breakpoint op:set pattern:`.
- Adds `location op:route maxSpeedKmh:` for driver-like speed changes.
- Improves `scroll_to_find`, `swipe`, `drag` and `hardware_button back`. (#271, #259, #274)
- Fixes system alerts swallowing taps on the iOS simulator. (#265, #258, #257, #255)
- Fixes several agents sharing one glint landing on each other's apps. (#279)
- Fixes missed inputs, checkbox state and coordinates in `get_scene` and `type`. (#273, #275, #272)

## [0.5.0] - 2026-10-19

- Adds `record touches:true` and `attach showTouches:true` to draw touches on video and in the app.
- Adds `attach camera:"webcam"` for an Android emulator's front camera. (#225)
- Adds `location op:route polylineId:` to play the route a Google map draws. (#229)
- Adds a once-per-session notice in `attach` when a newer glint is on pub.dev.
- Fixes slow Android typing and system dialogs swallowing in-app touches. (#219)
- Fixes `scroll_to_find` missing visible text and `notHittable` reports.
- Fixes taps reported as `changed: false` after a network request or system dialog. (#233)
- Fixes form fields, design-system buttons and faded controls in `get_scene`. (#234, #232, #220)
- Fixes GPX routes falling behind on the iOS simulator. (#230)

## [0.4.2] - 2026-10-15

- Adds install from pub.dev with `dart pub global activate glint_mcp`.
- Improves pub.dev scoring with an example, analysis options and formatting.
- Fixes the phone OCR reader and XCTest runner not found in a pub.dev install.

## [0.4.1] - 2026-10-15

- Fixes typing on a physical iPhone freezing on characters the keyboard cannot type.
- Fixes the local network prompt after `attach launch:` on a phone appearing late.
- Improves `device op:status` and Wi-Fi-only iPhone replies with clear next steps.
- Fixes the covered-app warning to say tap by text, not by x,y.

## [0.4.0] - 2026-10-15

- Adds the `pinch` tool, with real multi-touch on a physical iPhone.
- Adds `swipe edge:` and `hardware_button` back, `appSwitcher` and `unlock` on a physical iPhone.
- Adds `device op:openurl`, `device op:network` and `sensors op:set orientation:` on a phone.
- Adds `record`, `device op:status`, `sensors op:read` and `app_logs native:true` on a phone.
- Adds `attach launch:` to build and run on a physical iPhone, with `signingTeam:`.
- Adds `attach input:` (`app`, `device`, `auto`) and `data.input` delivery reports.
- Improves iPhone speed with faster screenshots and about twice as fast action replies.
- Fixes system surfaces reported as `nothing changed`, and `tap text:` on native surfaces.
- **Breaking:** Moves attach's tested-setup block from `data.input` to `data.setup`.
- **Breaking:** Replaces `unsupportedBackendAction` with `deviceBusy` and other device errorKinds.

## [0.3.0] - 2026-10-15

- Adds physical iPhone driving and `attach mode:device` for iPhones without a Flutter app. (#136)
- Adds the `location` and `map` tools and Google map reading in `get_scene`. (#148)
- Adds the `media` tool: seed, camera, event, listen, permission, pick and mic. (#137)
- Adds the `sensors` and `notifications` tools. (#162, #168)
- Adds `wait_for`, and `text:` targets for `tap`, `long_press` and `resolve`. (#165, #169)
- Adds `hot_reload`, `attach launch:` for installed apps and AVD boot. (#118, #103, #151)
- Adds device claims, session ownership and an XCUITest iOS backend. (#102, #118)
- Improves `get_scene` for go_router routes, tabs, nav bars, segments and app-bar buttons.
- Fixes `attach` picking the wrong app, device or backend. (#135, #139, #150, #161, #120)
- Fixes `get_scene` and `type` misses on dialogs, native UI and keys. (#111, #80, #171, #79, #75)
- **Breaking:** Makes `#hash` ids stable; they change once with this release, so re-read them.

## [0.2.0] - 2026-09-27

- Adds Xcode 27 support, with `dtuhidd` input so simulator taps and keys are not dropped. (#74)
- Adds a downloaded iOS bridge on first iOS attach; `GLINT_NO_BRIDGE_DOWNLOAD=true` skips it.
- Adds real hit testing (`hitBy`) and `notHittable` refusals. (#77)
- Adds `reason` to `scroll` when nothing moved. (#84)
- Adds `[selected]`, `[on]` and `[off]` states and image names to `get_scene`. (#78, #79)
- Adds screenshot shrinking (`screenshotMaxSize`) and native UI screenshots. (#89, #85)
- Adds Android system window detection with tap coordinates. (#80)
- Fixes ids, folded rows, spinners and overlays in `get_scene`. (#81, #82, #83, #86)
- Fixes iOS taps, keys and typing being lost or repeated.
- Fixes `telemetry audit_verify` and `report_issue` masking of tokens.
- **Breaking:** Refuses bridge actions on unverified Xcode; set `GLINT_ALLOW_UNTESTED_XCODE=true`.

## [0.1.0] - 2026-09-25

- Adds `get_scene`, a compact scene of the screen with ids an agent can act on.
- Adds actions (`tap`, `type`, `scroll`, `swipe`, `batch`) that report how the screen changed.
- Adds `attach` with no arguments, which finds the app and device and survives a hot restart.
- Adds device mode to drive a simulator or emulator without a Flutter app.
- Adds app logs, screen recording, Face ID and Touch ID, lock and unlock.
- Adds `report_issue`, which drafts first and redacts paths, tokens and passwords.
- Adds opt-in telemetry with `GLINT_TELEMETRY=on`.
