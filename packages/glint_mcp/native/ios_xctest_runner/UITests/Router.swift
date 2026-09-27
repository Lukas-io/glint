import XCTest

/// Bumped whenever a route's arguments or reply change; glint checks it before driving the runner.
let runnerProtocol = 1

private let springboardId = "com.apple.springboard"

/// Routes glint's requests to XCUITest; every point is in screen points.
final class Router {
    private var apps: [String: XCUIApplication] = [:]

    func handle(_ request: HttpRequest) -> HttpResponse {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        do {
            switch (request.method, request.path) {
            case ("GET", "/status"):
                return .ok(["runner": runnerProtocol, "os": UIDevice.current.systemVersion])
            case ("GET", "/tree"):
                return .ok(try tree(bundleId: request.query["app"]))
            case ("POST", "/tap"):
                try point(body, "x", "y").tap()
                return .ok(["done": "tap"])
            case ("POST", "/longpress"):
                try point(body, "x", "y").press(forDuration: seconds(body["ms"], or: 500))
                return .ok(["done": "longpress"])
            case ("POST", "/swipe"):
                let from = try point(body, "x1", "y1")
                let to = try point(body, "x2", "y2")
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: seconds(body["holdMs"], or: 0))
                return .ok(["done": "swipe"])
            case ("POST", "/type"):
                guard let text = body["text"] as? String else {
                    return .error(400, "invalidArgument", "type needs text")
                }
                app(body["app"] as? String).typeText(text)
                return .ok(["done": "type"])
            case ("POST", "/key"):
                guard let name = body["key"] as? String, let key = Self.keys[name] else {
                    return .error(400, "invalidArgument", "key must be one of \(Self.keys.keys.sorted())")
                }
                var flags: XCUIElement.KeyModifierFlags = []
                for m in body["mods"] as? [String] ?? [] {
                    guard let flag = Self.modifiers[m] else {
                        return .error(400, "invalidArgument", "mods must be from \(Self.modifiers.keys.sorted())")
                    }
                    flags.insert(flag)
                }
                let target = app(body["app"] as? String)
                for _ in 0..<max((body["count"] as? NSNumber)?.intValue ?? 1, 1) {
                    target.typeKey(key, modifierFlags: flags)
                }
                return .ok(["done": "key"])
            case ("POST", "/button"):
                guard let name = body["name"] as? String, let button = Self.buttons[name] else {
                    return .error(400, "invalidArgument", "button must be one of \(Self.buttons.keys.sorted())")
                }
                XCUIDevice.shared.press(button)
                return .ok(["done": "button"])
            case ("POST", "/shutdown"):
                return .ok(["done": "shutdown"])
            default:
                return .error(404, "unknownRoute", "\(request.method) \(request.path)")
            }
        } catch let error as RouteError {
            return .error(400, "invalidArgument", error.detail)
        } catch {
            return .error(500, "xctestFailed", "\(error)")
        }
    }

    private static let keys: [String: String] = [
        "backspace": XCUIKeyboardKey.delete.rawValue, "delete": XCUIKeyboardKey.forwardDelete.rawValue,
        "enter": XCUIKeyboardKey.return.rawValue, "tab": XCUIKeyboardKey.tab.rawValue,
        "escape": XCUIKeyboardKey.escape.rawValue, "space": XCUIKeyboardKey.space.rawValue,
        "up": XCUIKeyboardKey.upArrow.rawValue, "down": XCUIKeyboardKey.downArrow.rawValue,
        "left": XCUIKeyboardKey.leftArrow.rawValue, "right": XCUIKeyboardKey.rightArrow.rawValue,
        "a": "a",
    ]

    private static let modifiers: [String: XCUIElement.KeyModifierFlags] = [
        "cmd": .command, "shift": .shift, "ctrl": .control, "alt": .option,
    ]

    private static let buttons: [String: XCUIDevice.Button] = [
        "home": .home, "volumeUp": .volumeUp, "volumeDown": .volumeDown,
    ]

    private func app(_ bundleId: String?) -> XCUIApplication {
        let id = bundleId ?? springboardId
        if let cached = apps[id] { return cached }
        let created = XCUIApplication(bundleIdentifier: id)
        apps[id] = created
        return created
    }

    /// The screen point named by [xKey], [yKey], anchored on SpringBoard so it reaches whatever is on screen.
    private func point(_ body: [String: Any], _ xKey: String, _ yKey: String) throws -> XCUICoordinate {
        guard let x = (body[xKey] as? NSNumber)?.doubleValue, let y = (body[yKey] as? NSNumber)?.doubleValue else {
            throw RouteError(detail: "\(xKey) and \(yKey) must be numbers")
        }
        return app(nil).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func seconds(_ ms: Any?, or fallback: Double) -> TimeInterval {
        ((ms as? NSNumber)?.doubleValue ?? fallback) / 1000
    }

    /// The accessibility tree of [bundleId] (when given and running) plus any SpringBoard alert over it.
    private func tree(bundleId: String?) throws -> [String: Any] {
        var out: [String: Any] = [:]
        if let bundleId {
            let target = app(bundleId)
            out["state"] = Self.stateName(target.state)
            if target.state == .runningForeground {
                out["app"] = Self.node(try target.snapshot(), depth: 0)
            }
        }
        let alerts = app(nil).alerts
        if alerts.count > 0 {
            out["alerts"] = try alerts.allElementsBoundByIndex.map { Self.node(try $0.snapshot(), depth: 0) }
        }
        return out
    }

    private static func node(_ s: XCUIElementSnapshot, depth: Int) -> [String: Any] {
        var n: [String: Any] = ["type": typeName(s.elementType)]
        let f = s.frame
        n["frame"] = [f.origin.x, f.origin.y, f.size.width, f.size.height].map { ($0 * 10).rounded() / 10 }
        if !s.identifier.isEmpty { n["id"] = s.identifier }
        if !s.label.isEmpty { n["label"] = s.label }
        if let v = s.value as? String, !v.isEmpty { n["value"] = v }
        if let p = s.placeholderValue, !p.isEmpty { n["placeholder"] = p }
        if !s.isEnabled { n["enabled"] = false }
        if s.isSelected { n["selected"] = true }
        if depth < 80, !s.children.isEmpty {
            n["children"] = s.children.map { node($0, depth: depth + 1) }
        }
        return n
    }

    private static func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "suspended"
        case .runningBackground: return "background"
        case .runningForeground: return "foreground"
        default: return "unknown"
        }
    }

    private static func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "application"
        case .window: return "window"
        case .alert: return "alert"
        case .sheet: return "sheet"
        case .button: return "button"
        case .staticText: return "text"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .searchField: return "searchField"
        case .image: return "image"
        case .icon: return "icon"
        case .cell: return "cell"
        case .table: return "table"
        case .collectionView: return "collectionView"
        case .scrollView: return "scrollView"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .toolbar: return "toolbar"
        case .switch: return "switch"
        case .toggle: return "toggle"
        case .slider: return "slider"
        case .picker: return "picker"
        case .pickerWheel: return "pickerWheel"
        case .datePicker: return "datePicker"
        case .keyboard: return "keyboard"
        case .key: return "key"
        case .link: return "link"
        case .webView: return "webView"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .segmentedControl: return "segmentedControl"
        case .pageIndicator: return "pageIndicator"
        case .progressIndicator: return "progressIndicator"
        case .activityIndicator: return "activityIndicator"
        case .other: return "other"
        default: return "type\(t.rawValue)"
        }
    }
}

struct RouteError: Error {
    let detail: String
}
