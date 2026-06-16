// AxBridge.swift — reads the iOS Simulator window's native accessibility tree
// via macOS AXUIElement. The Simulator renders its content as a standard macOS
// window; AXUIElement can traverse it to expose native iOS elements (alerts,
// sheets, permission dialogs, etc.) that Flutter's widget tree cannot see.

import ApplicationServices
import AppKit

enum AxBridge {
    /// JSON string of the AX tree for the Simulator window matching `udid`.
    /// Returns nil when the Simulator process or device window cannot be found.
    static func snapshot(forSimulatorUdid udid: String) -> String? {
        guard let pid = simulatorPid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let win = findWindow(app: app) else { return nil }
        var nodes: [[String: Any]] = []
        walk(win, depth: 0, into: &nodes)
        guard let data = try? JSONSerialization.data(withJSONObject: nodes),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    // ── internals ─────────────────────────────────────────────────────────────

    private static func simulatorPid() -> pid_t? {
        let knownBundleIds = ["com.apple.CoreSimulator.SimulatorTrampoline",
                              "com.apple.iphonesimulator"]
        let knownNames = ["Simulator", "SimulatorTrampoline", "iOS Simulator"]
        let apps = NSWorkspace.shared.runningApplications
        // Try bundle ID first, then localised name.
        if let app = apps.first(where: { knownBundleIds.contains($0.bundleIdentifier ?? "") }) {
            return app.processIdentifier
        }
        return apps.first(where: { knownNames.contains($0.localizedName ?? "") })?.processIdentifier
    }

    private static func findWindow(app: AXUIElement) -> AXUIElement? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val) == .success,
              let wins = val as? [AXUIElement] else { return nil }
        return wins.first
    }

    private static func str(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let axVal = v else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(axVal as! AXValue, AXValueType.cgPoint, &pt) else { return nil }
        return pt
    }

    private static func size_(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let axVal = v else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(axVal as! AXValue, AXValueType.cgSize, &sz) else { return nil }
        return sz
    }

    /// Recursively walks the AX tree, depth-limited at 15 to bound output.
    private static func walk(_ el: AXUIElement, depth: Int, into out: inout [[String: Any]]) {
        guard depth < 15 else { return }
        let role    = str(el, kAXRoleAttribute as String) ?? "AXUnknown"
        let title   = str(el, kAXTitleAttribute as String) ?? ""
        let desc    = str(el, kAXDescriptionAttribute as String) ?? ""
        let value   = str(el, kAXValueAttribute as String) ?? ""
        let ident   = str(el, kAXIdentifierAttribute as String) ?? ""
        let label   = title.isEmpty ? desc : title

        var enabled = false
        var enVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enVal) == .success {
            enabled = (enVal as? Bool) ?? false
        }

        let pos = point(el, kAXPositionAttribute as String) ?? .zero
        let sz  = size_(el, kAXSizeAttribute as String) ?? .zero

        var node: [String: Any] = [
            "role": role, "label": label, "value": value,
            "ident": ident, "enabled": enabled,
            "frame": ["x": pos.x, "y": pos.y, "w": sz.width, "h": sz.height],
        ]

        var kidsVal: CFTypeRef?
        var childNodes: [[String: Any]] = []
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsVal) == .success,
           let kids = kidsVal as? [AXUIElement] {
            for kid in kids { walk(kid, depth: depth + 1, into: &childNodes) }
        }
        if !childNodes.isEmpty { node["children"] = childNodes }
        out.append(node)
    }
}
