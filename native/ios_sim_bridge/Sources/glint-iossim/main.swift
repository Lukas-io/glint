// glint-iossim — drives iOS Simulator touch input via private CoreSimulator
// APIs. Invoked as a child process by the glint Dart code's IosSimBackend.
//
// Status: P2.1 — protocol archaeology. The action commands (tap, swipe,
// type) are stubs until we map the modern `SimDeviceIOClient.ioPorts` HID
// surface. The diagnostic commands (list, dump-protocols, dump-classes,
// dump-port) are the tools we use to map it.
//
// Usage (diagnostic):
//   glint-iossim list
//   glint-iossim dump-protocols
//   glint-iossim dump-classes
//   glint-iossim dump-ports <UDID>
//   glint-iossim dump-port-protocol <UDID> <port-index>
//
// Usage (intended for backends, currently unimplemented):
//   glint-iossim tap   <UDID> <x> <y>
//   glint-iossim swipe <UDID> <x1> <y1> <x2> <y2> <duration_ms>
//
// Exits 0 on success, 1 on error with a one-line message on stderr.

import Foundation

let args = CommandLine.arguments
if args.count < 2 {
    print("usage: glint-iossim <list|dump-protocols|dump-classes|dump-ports|dump-port-protocol|tap|swipe> ...")
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
        // Surface every protocol declared by CoreSimulator / SimulatorKit
        // that's likely to be the HID/Indigo entry. Needles broad on
        // purpose — we'd rather over-dump and grep than miss it.
        try SimBridge.ensureLoaded()
        SimBridge.dumpProtocols(matching: [
            "SimDeviceIO",
            "Indigo",
            "HID",
            "Touch",
            "Pointer",
            "Consume",
            "Port",
        ])

    case "dump-classes":
        try SimBridge.ensureLoaded()
        SimBridge.dumpClasses(matching: [
            "Indigo",
            "SimDeviceIO",
            "SimDeviceLegacy",
            "HID",
            "Touch",
            "Pointer",
            "Digitizer",
        ])

    case "dump-ports":
        guard args.count == 3 else { die("usage: glint-iossim dump-ports <UDID>") }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        guard let io = (proxy.device as? NSObject)?.value(forKey: "io") as AnyObject? else {
            die("device.io returned nil")
        }
        guard let ports = (io as? NSObject)?.value(forKey: "ioPorts") as? [AnyObject] else {
            die("device.io.ioPorts returned nil")
        }
        print("## \(ports.count) ports ##\n")
        for (i, p) in ports.enumerated() {
            print("--- port[\(i)] ---")
            print("class = \(type(of: p))")
            // Try descriptor: every port should expose one telling us what
            // it is (HID/Display/etc.). Both `descriptor` and `port` (some
            // older builds) are worth probing.
            for sel in ["descriptor", "port", "deviceIO", "ioDescriptor", "descriptorType"] {
                if let v = (p as? NSObject)?.value(forKey: sel) {
                    print("  \(sel) = \(v)")
                }
            }
        }

    case "dump-class-methods":
        // Dump every method declared on a class. Usage:
        //   glint-iossim dump-class-methods <class-name>
        guard args.count == 3 else { die("usage: glint-iossim dump-class-methods <class>") }
        try SimBridge.ensureLoaded()
        guard let cls = NSClassFromString(args[2]) else {
            die("class '\(args[2])' not found (CoreSimulator/SimulatorKit loaded?)")
        }
        SimBridge.dumpAllMethods(of: cls)

    case "dump-port-protocol":
        // Walk the port's adopted-protocols and dump methods of each. The
        // ROCK proxy's class doesn't carry the methods directly, but the
        // protocols it impersonates DO carry the metadata.
        guard args.count == 4 else { die("usage: glint-iossim dump-port-protocol <UDID> <port-index>") }
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
        // ROCKRemoteProxy stores its impersonated protocol(s) as a property.
        // The name varies — try common keys.
        for sel in ["protocols", "interfaces", "impersonatedProtocols", "remoteProtocols"] {
            if let v = (p as? NSObject)?.value(forKey: sel) {
                print("\n\(sel) = \(v)")
                if let arr = v as? [AnyObject] {
                    for proto in arr {
                        if let p = proto as? Protocol {
                            let name = String(cString: protocol_getName(p))
                            print("\n## adopted protocol \(name) ##")
                            for (req, inst) in [(true, true), (false, true)] {
                                var mcount: UInt32 = 0
                                guard let methods = protocol_copyMethodDescriptionList(p, req, inst, &mcount) else { continue }
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
                }
            }
        }

    case "tap":
        guard args.count == 7 else {
            die("usage: glint-iossim tap <UDID> <dev_w> <dev_h> <x> <y>")
        }
        let proxy = try SimBridge.requireBootedDevice(udid: args[2])
        let dw = Double(args[3]) ?? -1
        let dh = Double(args[4]) ?? -1
        let x = Double(args[5]) ?? -1
        let y = Double(args[6]) ?? -1
        guard dw > 0, dh > 0 else { die("dev_w/dev_h must be positive numbers") }
        try proxy.tap(x: x, y: y, deviceLogicalSize: CGSize(width: dw, height: dh))
        print("OK tap \(args[2]) (\(x),\(y)) of (\(dw)x\(dh))")

    case "swipe":
        die("swipe not yet implemented — wiring up after tap proof")

    default:
        die("unknown command: \(command)")
    }
} catch {
    die("\(command) failed: \(error.localizedDescription)")
}
