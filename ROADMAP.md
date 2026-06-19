# glint roadmap

Major capabilities not yet built. Simple, cheap reads land opportunistically
inside existing tools (e.g. `attach` already returns device/app identity +
screen context); the heavier control surface is tracked here.

## 1. Device mode — drive a simulator without a Flutter app  *(IN PROGRESS)*

Today `attach` requires a Flutter debug isolate (`vm_client.dart` throws if no
`ext.flutter.*`). The interaction backends are already OS-level and
coordinate-native (`AdbBackend`, `IosSimBackend`), and `glint-iossim` already
has `ax-snapshot` for the OS accessibility tree. What's left:

- `attach` device-mode binding (no VM/scene; viewport from `simctl` / `wm size`).
- Coordinate-targeting in `tap`/`swipe`/`scroll` (opt-in raw-pixel flag, default
  logical points). This is the same work as the audit's "no coordinate fallback"
  gap in #145/#147/#149.
- Dual perception:
  - **Screenshot** (`simctl io screenshot`) — works headless, no permission;
    the robust default. Interaction needs no dpr: IndigoHID takes a 0–1 ratio,
    so `tap = pixel / screenshotSize`.
  - **OS AX-tree** (`glint-iossim ax-snapshot`) — structured + token-efficient,
    sees native system dialogs invisible to the widget tree, but needs
    Simulator.app GUI open **and** macOS Accessibility permission granted to the
    calling process. Enhancement layer, not the baseline.

Build as one vertical slice so it's testable end-to-end, not orphaned plumbing.

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
