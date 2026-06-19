# glint roadmap

Major capabilities not yet built. Simple, cheap reads land opportunistically
inside existing tools (e.g. `attach` already returns device/app identity +
screen context); the heavier control surface is tracked here.

## 1. Device mode — drive a simulator without a Flutter app

Today `attach` requires a Flutter debug isolate (`vm_client.dart` throws if no
`ext.flutter.*`). The interaction backends are already OS-level and
coordinate-native (`AdbBackend`, `IosSimBackend`), and `glint-iossim` already
has `ax-snapshot` for the OS accessibility tree. What's left:

- `attach` device-mode binding (no VM/scene; viewport from `simctl` / `wm size`).
- Coordinate-targeting in `tap`/`swipe`/`scroll` (opt-in raw-pixel flag, default
  logical points). This is the same work as the audit's "no coordinate fallback"
  gap in #145/#147/#149.
- Dual perception: OS AX-tree (sees native system dialogs invisible to the
  widget tree) + screenshots (new native op in `glint-iossim`).

Build as one vertical slice so it's testable end-to-end, not orphaned plumbing.

## 2. Device / sim status + control tool

glint can *drive* a sim but can't *report on or configure* it. Proposed
`device` tool (status reads + control ops), most via `simctl`.

### Status (reads)
| Item | Mechanism | Notes |
|------|-----------|-------|
| name / model / OS version | `simctl list -j` | ✅ shipped in `attach` |
| app name / bundle id | CoreSimulator path / `simctl listapps` | name ✅ in `attach`; bundle id TODO |
| appearance (light/dark) | `simctl ui <udid> appearance` | also via app `platformBrightness` |
| content size (text scale) | `simctl ui <udid> content_size` | accessibility |
| **locked state** | SpringBoard AX snapshot | hard — needs AX inspection / private API |
| **location** | reading current GPS | hard — `simctl location` is set-only |
| **biometrics enrollment** | SimulatorKit / Features state | hard — no clean public read |

### Control (writes)
| Op | Mechanism |
|----|-----------|
| lock / unlock | lock = IndigoHID code 1 (shipped in backend); unlock = two keystrokes, or Darwin `pearl.match` + bottom-edge swipe (shipped) |
| set location | `simctl location <udid> set <lat>,<lon>` (+ `run` for routes) |
| biometric match / non-match | `notifyutil -p com.apple.BiometricKit_Sim.pearl.match` / `.nomatch` |
| appearance light/dark | `simctl ui <udid> appearance <mode>` |
| privacy grant/revoke | `simctl privacy <udid> grant|revoke <service> <bundle>` |
| status bar override | `simctl status_bar <udid> override` (time/battery/cellular) |
| push notification | `simctl push <udid> <bundle> <payload.json>` |
| open url / deeplink | `simctl openurl <udid> <url>` |
| pasteboard / media | `simctl pbcopy|pbpaste`, `simctl addmedia` |
| app lifecycle | `simctl launch|terminate|install|uninstall` |

Android equivalents exist for most via `adb` (`adb emu geo fix`, `pm grant`,
`am broadcast`, `cmd appops`, etc.).
