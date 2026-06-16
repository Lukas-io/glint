// glint-iossim — drives iOS Simulator HID input via private CoreSimulator
// / SimulatorKit. Invoked as a child process by IosSimBackend.
//
// Action commands: tap / long-press / swipe / button / type.
// Diagnostic commands: list / dump-protocols / dump-classes /
// dump-class-methods / dump-ports / dump-port-protocol / probe-button.
//
// Exits 0 on success, 1 on error with a one-line message on stderr.

import Foundation

/// SimulatorKit's IndigoHIDButton enum case → integer code passed to
/// IndigoHIDMessageForButton. Codes empirically calibrated for Xcode 26;
/// per-release updates land in source-of-truth §13.
enum SimButton: String, CaseIterable {
    case home, lock, side, siri

    var code: Int32 {
        switch self {
        case .home: return 1
        case .lock: return 2
        case .side: return 4
        case .siri: return 5
        }
    }
}

let args = CommandLine.arguments
if args.count < 2 {
    print("usage: glint-iossim <list|dump-*|tap|long-press|swipe|button|probe-button|type> ...")
    exit(2)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let command = args[1]

do {
    switch command {
    case "list":
        for d in try SimBridge.bootedDevices() {
            print("\(d.udid)\t\(d.name)")
        }

    case "dump-protocols":
        try SimBridge.ensureLoaded()
        SimBridge.dumpProtocols(matching: [
            "SimDeviceIO", "Indigo", "HID", "Touch", "Pointer", "Consume", "Port",
        ])

    case "dump-classes":
        try SimBridge.ensureLoaded()
        SimBridge.dumpClasses(matching: [
            "Indigo", "SimDeviceIO", "SimDeviceLegacy", "HID", "Touch", "Pointer", "Digitizer",
        ])

    case "dump-class-methods":
        guard args.count == 3 else { die("usage: glint-iossim dump-class-methods <class>") }
        try SimBridge.ensureLoaded()
        guard let cls = NSClassFromString(args[2]) else {
            die("class '\(args[2])' not found (CoreSimulator/SimulatorKit loaded?)")
        }
        SimBridge.dumpAllMethods(of: cls)

    case "dump-ports":
        guard args.count == 3 else { die("usage: glint-iossim dump-ports <UDID>") }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        guard let io = (proxy.device as? NSObject)?.value(forKey: "io") as AnyObject?
        else { die("device.io returned nil") }
        guard let ports = (io as? NSObject)?.value(forKey: "ioPorts") as? [AnyObject]
        else { die("device.io.ioPorts returned nil") }
        print("## \(ports.count) ports ##\n")
        for (i, p) in ports.enumerated() {
            print("--- port[\(i)] ---")
            print("class = \(type(of: p))")
            // Both old and new builds expose one of these keys.
            for sel in ["descriptor", "port", "deviceIO", "ioDescriptor", "descriptorType"] {
                if let v = (p as? NSObject)?.value(forKey: sel) {
                    print("  \(sel) = \(v)")
                }
            }
        }

    case "dump-port-protocol":
        // ROCK proxies don't carry method tables directly; the protocols
        // they impersonate do.
        guard args.count == 4 else {
            die("usage: glint-iossim dump-port-protocol <UDID> <port-index>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        guard let portIndex = Int(args[3]) else { die("port-index must be int") }
        guard let io = (proxy.device as? NSObject)?.value(forKey: "io") as AnyObject?,
              let ports = (io as? NSObject)?.value(forKey: "ioPorts") as? [AnyObject],
              portIndex < ports.count
        else { die("invalid port index") }
        let p = ports[portIndex]
        let cls: AnyClass = object_getClass(p)!
        print("class chain:")
        var c: AnyClass? = cls
        while let cur = c {
            print("  \(NSStringFromClass(cur))")
            c = class_getSuperclass(cur)
            if c == NSObject.self { print("  NSObject"); break }
        }
        for sel in ["protocols", "interfaces", "impersonatedProtocols", "remoteProtocols"] {
            guard let v = (p as? NSObject)?.value(forKey: sel) else { continue }
            print("\n\(sel) = \(v)")
            guard let arr = v as? [AnyObject] else { continue }
            for proto in arr {
                guard let p = proto as? Protocol else { continue }
                let name = String(cString: protocol_getName(p))
                print("\n## adopted protocol \(name) ##")
                for (req, inst) in [(true, true), (false, true)] {
                    var mcount: UInt32 = 0
                    guard let methods = protocol_copyMethodDescriptionList(
                        p, req, inst, &mcount,
                    ) else { continue }
                    let prefix = inst ? "-" : "+"
                    let tag = req ? "@required" : "@optional"
                    for j in 0..<Int(mcount) {
                        let m = methods[j]
                        let selName = m.name.map { NSStringFromSelector($0) } ?? "<?>"
                        let types = m.types.map { String(cString: $0) } ?? "<?>"
                        print("  \(tag) \(prefix)[\(selName)]  types=\(types)")
                    }
                    free(methods)
                }
            }
        }

    case "tap":
        guard args.count == 7 else {
            die("usage: glint-iossim tap <UDID> <dev_w> <dev_h> <x> <y>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        let p = try _Point.parse(dwStr: args[3], dhStr: args[4], xStr: args[5], yStr: args[6])
        try proxy.tap(x: p.x, y: p.y, deviceLogicalSize: p.size)
        print("OK tap \(args[2]) (\(p.x),\(p.y)) of (\(p.size.width)x\(p.size.height))")

    case "long-press":
        guard args.count == 8 else {
            die("usage: glint-iossim long-press <UDID> <dev_w> <dev_h> <x> <y> <duration_ms>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        let p = try _Point.parse(dwStr: args[3], dhStr: args[4], xStr: args[5], yStr: args[6])
        guard let dur = Int(args[7]), dur > 0 else { die("duration_ms must be positive") }
        try proxy.longPress(x: p.x, y: p.y, deviceLogicalSize: p.size, durationMs: dur)
        print("OK long-press \(args[2]) (\(p.x),\(p.y)) hold=\(dur)ms")

    case "swipe":
        guard args.count == 10 else {
            die("usage: glint-iossim swipe <UDID> <dev_w> <dev_h> <x1> <y1> <x2> <y2> <duration_ms>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        let size = try _Point.parseSize(args[3], args[4])
        guard let x1 = Double(args[5]), let y1 = Double(args[6]),
              let x2 = Double(args[7]), let y2 = Double(args[8]),
              let dur = Int(args[9]), dur > 0 else {
            die("x1/y1/x2/y2/duration_ms must be valid numbers")
        }
        try proxy.swipe(
            from: CGPoint(x: x1, y: y1),
            to: CGPoint(x: x2, y: y2),
            deviceLogicalSize: size,
            durationMs: dur,
        )
        print("OK swipe \(args[2]) (\(x1),\(y1)) -> (\(x2),\(y2)) dur=\(dur)ms")

    case "button":
        guard args.count == 4 else {
            die("usage: glint-iossim button <UDID> <\(SimButton.allCases.map(\.rawValue).joined(separator: "|"))>")
        }
        guard let button = SimButton(rawValue: args[3]) else {
            die("unknown button: \(args[3])")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        try proxy.pressButton(button.code)
        print("OK button \(args[2]) \(button.rawValue)")

    case "probe-button":
        // Calibration helper: fire IndigoHIDMessageForButton with a raw
        // int. Used to identify per-Xcode-release button codes.
        guard args.count == 4, let code = Int32(args[3]) else {
            die("usage: glint-iossim probe-button <UDID> <int-code>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        try proxy.pressButton(code)
        print("OK probe-button \(args[2]) code=\(code)")

    case "type":
        guard args.count == 4 else { die("usage: glint-iossim type <UDID> <text>") }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        try proxy.typeText(args[3])
        print("OK type \(args[2]) \(args[3].count) chars")

    case "ax-snapshot":
        // Read the iOS Simulator window's accessibility tree via macOS AXUIElement.
        // Works because the Simulator renders as a standard macOS window whose
        // AX hierarchy exposes native iOS elements (alerts, sheets, pickers, etc.).
        // Requires the standard macOS accessibility permission.
        guard args.count == 3 else { die("usage: glint-iossim ax-snapshot <UDID>") }
        let targetUdid = args[2].uppercased()
        guard let snapshot = AxBridge.snapshot(forSimulatorUdid: targetUdid) else {
            die("ax-snapshot: Simulator window not found for UDID \(targetUdid). "
                + "Is the device booted and is the Simulator app running?")
        }
        print(snapshot)

    default:
        die("unknown command: \(command)")
    }
} catch {
    die("\(command) failed: \(error.localizedDescription)")
}

/// Parses positional dev_w / dev_h / x / y CLI args into a typed pair.
struct _Point {
    let x: Double
    let y: Double
    let size: CGSize

    static func parse(
        dwStr: String, dhStr: String, xStr: String, yStr: String,
    ) throws -> _Point {
        let size = try parseSize(dwStr, dhStr)
        guard let x = Double(xStr), let y = Double(yStr) else {
            throw SimError(message: "x/y must be numbers")
        }
        return _Point(x: x, y: y, size: size)
    }

    static func parseSize(_ dwStr: String, _ dhStr: String) throws -> CGSize {
        guard let dw = Double(dwStr), let dh = Double(dhStr), dw > 0, dh > 0 else {
            throw SimError(message: "dev_w/dev_h must be positive numbers")
        }
        return CGSize(width: dw, height: dh)
    }
}
