# glint roadmap

Major capabilities not yet built. Simple, cheap reads land opportunistically
inside existing tools (e.g. `attach` already returns device/app identity +
screen context); the heavier control surface is tracked here.

## 1. Device mode — drive a simulator without a Flutter app  *(SHIPPED)*

`attach mode:device` (or auto, when no running app is found) binds a sim with
no VM and drives it directly. Shipped + live-verified:
- ✅ `attach` device-mode binding — iOS sized to the screenshot, dpr=1.
- ✅ Coordinate `tap` / `swipe` (x,y) — device mode: screenshot pixels;
  flutter mode: logical points. Backend-direct, bypasses glintId (also the
  audit's #145/#147 "no coordinate fallback" fix).
- ✅ Screenshot perception (`device op:screenshot`); `get_scene` redirects.

Why it was straightforward: the interaction backends were already OS-level and
coordinate-native (`AdbBackend`, `IosSimBackend`); the Flutter coupling lived
only in the tool layer. IndigoHID takes a 0–1 ratio, so taps need no dpr lookup
(`tap = pixel / screenshotSize`).

Follow-up (not yet done):
- Coordinate `long_press` / `drag` / `scroll` (tap + swipe done; same pattern).
- Android device-mode is wired (adb backend) but not live-tested.

### Deferred: OS AX-tree perception
`glint-iossim ax-snapshot` reads the native accessibility tree (structured,
token-efficient, sees native system dialogs the widget tree can't). Deferred —
it needs the Simulator.app GUI open **and** macOS Accessibility permission
granted to the calling process, which is redundant and complex next to
screenshots. Revisit only if a concrete need surfaces.

## 2. Device / sim status + control tool  *(SHIPPED — `device` tool)*

The `device` tool ships status reads + light control via `simctl`. Heavier
control below is still roadmapped.

### Status (reads)
| Item | Mechanism | Notes |
|------|-----------|-------|
| name / model / OS version | `simctl list -j` | ✅ `attach` + `device status` |
| app name / bundle id | CoreSimulator path / `simctl listapps` | name ✅ in `attach`; bundle id TODO |
| appearance (light/dark) | `simctl ui <udid> appearance` | ✅ `device status` |
| content size (text scale) | `simctl ui <udid> content_size` | ✅ `device status` |
| **locked state** | SpringBoard AX snapshot | hard — needs AX inspection / private API |
| **location** | reading current GPS | hard — `simctl location` is set-only |
| **biometrics enrollment** | SimulatorKit / Features state | hard — no clean public read |

### Control (writes)
| Op | Mechanism | Status |
|----|-----------|--------|
| appearance light/dark | `simctl ui <udid> appearance <mode>` | ✅ `device appearance` |
| open url / deeplink | `simctl openurl <udid> <url>` | ✅ `device openurl` |
| privacy grant/revoke/reset | `simctl privacy <udid> grant\|revoke\|reset <service> <bundle>` | ✅ `device privacy` |
| lock / unlock | lock = IndigoHID code 1; unlock = two keystrokes, or Darwin `pearl.match` + bottom-edge swipe | shipped in backend (not yet a `device` op) |
| set location | `simctl location <udid> set <lat>,<lon>` (+ `run` for routes) | roadmap |
| biometric match / non-match | `notifyutil -p com.apple.BiometricKit_Sim.pearl.match` / `.nomatch` | roadmap |
| status bar override | `simctl status_bar <udid> override` (time/battery/cellular) | roadmap |
| push notification | `simctl push <udid> <bundle> <payload.json>` | roadmap |
| pasteboard / media | `simctl pbcopy\|pbpaste`, `simctl addmedia` | roadmap |
| app lifecycle | `simctl launch\|terminate\|install\|uninstall` | roadmap |

Android equivalents exist for most via `adb` (`adb emu geo fix`, `pm grant`,
`am broadcast`, `cmd appops`, etc.).
