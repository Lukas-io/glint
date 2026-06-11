// SimBridge.swift — investigates private CoreSimulator / SimulatorKit
// surface so glint can drive iOS Simulator touch input through Apple's
// own HID stream (not via macOS GUI events).
//
// Status: P2.1 — protocol archaeology phase. The legacy path
// `-[SimDevice sendEvent:]` is gone in modern Xcode. The replacement
// lives behind `SimDeviceIOClient.ioPorts`, each of which is an XPC
// `ROCKRemoteProxy`. We need to:
//   1. Dump the protocols Apple's binaries declare (the protocol metadata
//      survives even when implementations are XPC-forwarded).
//   2. Identify which port is the HID (Indigo) port via its descriptor.
//   3. Find the consumer entry point and the wire format for HID events.
//
// Once mapped, the per-Xcode Swift module compiles against this protocol
// and is the canonical glint-iossim backend for that Xcode major release.
// Compat matrix lives in source-of-truth §13.
//
// Historical reference: FBSimulatorControl / idb implemented this on
// Xcode 14 and earlier (FBSimulatorControl/FBSimulatorIOClient.m). The
// pattern those projects used was:
//   - Find port with descriptor.UUID == kSimDeviceIOIndigoDescriptorUUID
//   - Build IndigoMessage binary (touch type, finger index, x/y, ts)
//   - Call -[port consumeData:] (or similar) with NSData wrapping the message
//
// Whether that exact shape survives in Xcode 26 is what this scaffold
// answers.

import Foundation

struct SimError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BootedDevice {
    let udid: String
    let name: String
}

enum SimBridge {
    private static var loaded = false

    /// Load every private framework whose protocols/classes we may need to
    /// dump or call. `RTLD_LAZY` so we don't pay for symbol resolution we
    /// don't use. The frameworks ship inside Xcode; if Xcode isn't
    /// installed at the path the user's `xcode-select` points to, we
    /// surface that as a clear error.
    static func ensureLoaded() throws {
        if loaded { return }
        let devDir = developerDir() as String
        let frameworks = [
            "\(devDir)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(devDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            // Fallbacks for systems where CoreSimulator is in /Library, not
            // inside Xcode's developer dir.
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]
        var loadedAny = false
        for path in frameworks {
            if FileManager.default.fileExists(atPath: path),
               dlopen(path, RTLD_LAZY) != nil {
                loadedAny = true
            }
        }
        guard loadedAny else {
            throw SimError(message:
                "could not dlopen CoreSimulator from \(devDir). Is Xcode installed " +
                "and `xcode-select -p` pointing to a valid developer directory?")
        }
        loaded = true
    }

    static func bootedDevices() throws -> [BootedDevice] {
        try ensureLoaded()
        guard let SimServiceContext = NSClassFromString("SimServiceContext") else {
            throw SimError(message: "SimServiceContext class not found")
        }
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let ctx = (SimServiceContext as AnyObject)
            .perform(sel, with: developerDir(), with: NSNull())?
            .takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "sharedServiceContextForDeveloperDir returned nil")
        }
        guard let set = ctx.perform(
            NSSelectorFromString("defaultDeviceSetWithError:"),
            with: NSNull()
        )?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "defaultDeviceSetWithError returned nil")
        }
        guard let devices = set.perform(NSSelectorFromString("devices"))?
            .takeUnretainedValue() as? [AnyObject] else {
            throw SimError(message: "devices returned nil")
        }
        var out: [BootedDevice] = []
        for d in devices {
            let state = ((d as? NSObject)?.value(forKey: "state") as? NSNumber)?.intValue ?? -1
            if state != 3 { continue }  // 3 == Booted
            let udid = ((d as? NSObject)?.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
            let name = ((d as? NSObject)?.value(forKey: "name") as? String) ?? ""
            out.append(BootedDevice(udid: udid, name: name))
        }
        return out
    }

    static func requireBootedDevice(udid: String) throws -> SimDeviceProxy {
        try ensureLoaded()
        guard let SimServiceContext = NSClassFromString("SimServiceContext") else {
            throw SimError(message: "SimServiceContext class not found")
        }
        guard let ctx = (SimServiceContext as AnyObject).perform(
            NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
            with: developerDir(), with: NSNull()
        )?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "sharedServiceContextForDeveloperDir returned nil")
        }
        guard let set = ctx.perform(
            NSSelectorFromString("defaultDeviceSetWithError:"), with: NSNull()
        )?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "defaultDeviceSetWithError returned nil")
        }
        guard let devices = set.perform(NSSelectorFromString("devices"))?
            .takeUnretainedValue() as? [AnyObject] else {
            throw SimError(message: "devices returned nil")
        }
        let target = udid.uppercased()
        for d in devices {
            let did = ((d as? NSObject)?.value(forKey: "UDID") as? NSUUID)?.uuidString.uppercased() ?? ""
            if did == target {
                return SimDeviceProxy(device: d)
            }
        }
        throw SimError(message: "no SimDevice with UDID \(udid)")
    }

    private static func developerDir() -> NSString {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            return env as NSString
        }
        let p = Process()
        p.launchPath = "/usr/bin/xcode-select"
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s as NSString
        } catch {
            return "/Applications/Xcode.app/Contents/Developer" as NSString
        }
    }

    static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[glint-iossim] \(msg)\n".utf8))
    }

    // MARK: - Protocol archaeology
    //
    // The two next sections are diagnostic-only. Output goes to stdout in a
    // shape that's easy to grep / pipe to `tee` / save as evidence.

    /// Dump every ObjC protocol whose name matches one of the needles.
    /// Protocols come from frameworks we've already loaded — call after
    /// `ensureLoaded()`.
    static func dumpProtocols(matching needles: [String]) {
        var count: UInt32 = 0
        guard let list = objc_copyProtocolList(&count) else {
            print("no protocols")
            return
        }
        let needlesLower = needles.map { $0.lowercased() }
        for i in 0..<Int(count) {
            let p: Protocol = list[i]
            let name = String(cString: protocol_getName(p))
            let lower = name.lowercased()
            guard needlesLower.contains(where: { lower.contains($0) }) else { continue }
            print("\n## protocol \(name) ##")
            // Required / optional × instance / class methods. objc4's
            // method_description struct exposes name/types as optionals
            // post-Swift-5.9, so we have to nil-check both.
            for (req, inst) in [(true, true), (true, false), (false, true), (false, false)] {
                var mcount: UInt32 = 0
                guard let methods = protocol_copyMethodDescriptionList(
                    p, req, inst, &mcount
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
            // Adopted protocols.
            var pcount: UInt32 = 0
            if let adopted = protocol_copyProtocolList(p, &pcount), pcount > 0 {
                let names = (0..<Int(pcount)).map { String(cString: protocol_getName(adopted[$0])) }
                print("  conforms-to: \(names.joined(separator: ", "))")
                free(UnsafeMutableRawPointer(adopted))
            }
        }
        free(UnsafeMutableRawPointer(list))
    }

    /// Dump every class whose name contains any of `needles` (case-insensitive).
    /// Used to find `IndigoMessage`, the descriptor types, etc.
    static func dumpClasses(matching needles: [String]) {
        let expected = objc_getClassList(nil, 0)
        guard expected > 0 else {
            print("(no classes registered yet)")
            return
        }
        let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(expected))
        defer { buf.deallocate() }
        let n = Int(objc_getClassList(
            AutoreleasingUnsafeMutablePointer<AnyClass>(buf), expected))
        let needlesLower = needles.map { $0.lowercased() }
        var matched = 0
        for i in 0..<n {
            let cls: AnyClass = buf[i]
            let name = NSStringFromClass(cls)
            let lower = name.lowercased()
            if needlesLower.contains(where: { lower.contains($0) }) {
                print("- \(name)")
                matched += 1
            }
        }
        print("(\(matched) classes matched; \(n) total registered)")
    }

    /// Dump every instance and class method declared on a class, plus its
    /// adopted protocols. Walks superclasses up to (but not including)
    /// NSObject so we don't drown in inherited boilerplate.
    static func dumpAllMethods(of cls: AnyClass) {
        var c: AnyClass? = cls
        while let cur = c {
            let name = NSStringFromClass(cur)
            print("== \(name) ==")
            // Adopted protocols on this class only.
            var pcount: UInt32 = 0
            if let protos = class_copyProtocolList(cur, &pcount), pcount > 0 {
                let names = (0..<Int(pcount)).map { String(cString: protocol_getName(protos[$0])) }
                print("  conforms-to: \(names.joined(separator: ", "))")
            }
            for forClass in [false, true] {
                let target: AnyClass = forClass ? object_getClass(cur)! : cur
                var mcount: UInt32 = 0
                if let methods = class_copyMethodList(target, &mcount) {
                    let prefix = forClass ? "+" : "-"
                    for i in 0..<Int(mcount) {
                        let m = methods[i]
                        let sel = NSStringFromSelector(method_getName(m))
                        let types = method_getTypeEncoding(m).map { String(cString: $0) } ?? "<?>"
                        print("  \(prefix)[\(name) \(sel)]  types=\(types)")
                    }
                    free(methods)
                }
            }
            c = class_getSuperclass(cur)
            if c == NSObject.self { break }
        }
    }

    /// Enumerate ObjC methods on a class chain whose name contains any of
    /// the given substrings (case-insensitive).
    static func dumpDeviceMethods(of device: AnyObject, matching needles: [String]) {
        var cls: AnyClass? = object_getClass(device)
        let lowerNeedles = needles.map { $0.lowercased() }
        while let c = cls {
            print("== \(NSStringFromClass(c)) ==")
            var count: UInt32 = 0
            if let methods = class_copyMethodList(c, &count) {
                for i in 0..<Int(count) {
                    let m = methods[i]
                    let name = NSStringFromSelector(method_getName(m)).lowercased()
                    if lowerNeedles.contains(where: { name.contains($0) }) {
                        let types = String(cString: method_getTypeEncoding(m)!)
                        print("  -[\(NSStringFromClass(c)) \(NSStringFromSelector(method_getName(m)))]  types=\(types)")
                    }
                }
                free(methods)
            }
            cls = class_getSuperclass(c)
            if cls == NSObject.self { break }
        }
    }
}

/// Wraps a private `SimDevice` ObjC instance and exposes the actions we
/// need. Xcode 26 path: `SimulatorKit.SimDeviceLegacyHIDClient` accepts
/// an `IndigoHIDMessageStruct*` via `send(message:...)`. The message is
/// built by SimulatorKit's exported C function
/// `IndigoHIDMessageForMouseNSEvent`; idb's reverse engineering
/// (FBSimulatorIndigoHID.m) showed the touch-ratio fields live at byte
/// offsets `0x3C` (xRatio) and `0x44` (yRatio) of the returned message.
/// We patch those with the ratio (0..1) of our tap point against the
/// device's logical bounds.
struct SimDeviceProxy {
    let device: AnyObject

    // ── Direction codes for IndigoHIDMessageForMouseNSEvent's `eventType` arg.
    // Same values idb uses; mapping verified by experiment in P2.1.
    private static let touchDown: Int32 = 1
    private static let touchUp: Int32 = 2

    // Display target. idb hardcodes `0x32` = 50 (the simulator's
    // "main display" target id). Tested unchanged through Xcode 14 → 26.
    private static let displayTarget: Int32 = 0x32

    // Xcode-26 IndigoHIDMessageStruct layout (verified by `swift build &&
    // glint-iossim tap` + hex dump):
    //
    //   0x00..0x17  (24 bytes) — outer envelope, all zeros from the builder
    //   0x18..0x1B   innerSize          = 0xA0 (one IndigoPayload)
    //   0x1C..0x1F   eventType          = 2 (IndigoEventTypeTouch)
    //   0x20..0xBF   payload[0] — 160 bytes
    //     0x20..0x23   payload.field1   = 0x0B
    //     0x24..0x2B   payload.timestamp (mach_absolute_time)
    //     0x2C..0x33   touch.field1/field2/field3 (uint32 × 3)
    //     0x34..0x3B   touch.field4 / pad / pad
    //     0x3C..0x43   touch.xRatio (double)
    //     0x44..0x4B   touch.yRatio (double)
    //     ...
    //   0xC0..0x15F  payload[1] (digitizer summary; mirrors payload[0])
    //     0xCC..0xCF   payload[1].touch.field1 = 1 (digitizer marker)
    //     0xD0..0xD3   payload[1].touch.field2 = 2 (digitizer marker)
    //     0xDC..0xE3   payload[1].touch.xRatio
    //     0xE4..0xEB   payload[1].touch.yRatio
    //
    // Total message size = 0x20 (outer + inner header) + 2 * 0xA0 = 0x160 (352).
    private static let payloadStride = 0xA0
    private static let messageHeaderSize = 0x20
    private static let totalMessageSize = 0x20 + 2 * 0xA0   // 0x160
    private static let xRatioOffset0 = 0x3C   // payload[0].touch.xRatio
    private static let yRatioOffset0 = 0x44
    private static let xRatioOffset1 = 0xDC   // payload[1].touch.xRatio
    private static let yRatioOffset1 = 0xE4
    private static let p1TouchField1Offset = 0xCC
    private static let p1TouchField2Offset = 0xD0

    /// Tap at logical device coordinates (`x`, `y` in points, normalised
    /// against `deviceLogicalSize.width/height` to get the 0..1 ratio the
    /// HID message takes).
    func tap(x: Double, y: Double,
             deviceLogicalSize: CGSize) throws {
        let ratio = CGPoint(x: x / deviceLogicalSize.width,
                            y: y / deviceLogicalSize.height)
        let client = try makeHidClient()
        try sendTouch(client: client, ratio: ratio, direction: Self.touchDown)
        // Held-down dwell so the OS recognises it as a tap; idb used ~50ms.
        Thread.sleep(forTimeInterval: 0.05)
        try sendTouch(client: client, ratio: ratio, direction: Self.touchUp)
    }

    private func sendTouch(client: AnyObject,
                           ratio: CGPoint,
                           direction: Int32) throws {
        guard let builderSym = dlsym(SimBridge.simulatorKitHandle(), "IndigoHIDMessageForMouseNSEvent") else {
            throw SimError(message:
                "dlsym(IndigoHIDMessageForMouseNSEvent) failed: " +
                String(cString: dlerror()))
        }
        typealias Builder = @convention(c) (
            UnsafePointer<CGPoint>,
            UnsafePointer<CGPoint>?,
            Int32,
            Int32,
            DarwinBoolean
        ) -> UnsafeMutableRawPointer?
        let build = unsafeBitCast(builderSym, to: Builder.self)
        // `point` carries the ratio; idb fed the same value as both
        // (point arg + patched offset). The patched offset is what the
        // simulator actually reads, but we feed both for parity in case
        // a future SimulatorKit decides to use the arg.
        var point = ratio
        guard let oneShot = build(&point, nil, Self.displayTarget, direction,
                                  DarwinBoolean(false)) else {
            throw SimError(message:
                "IndigoHIDMessageForMouseNSEvent returned nil for (\(ratio.x), \(ratio.y))")
        }
        // The builder returns a 1-payload (160-byte payload) message. The
        // simulator's HID stream actually consumes a 2-payload message:
        // payload[0] is the finger event, payload[1] is the digitizer
        // summary (mirrors payload[0] but with touch.field1=1, field2=2).
        // We reconstruct that here following idb/FBSimulatorIndigoHID's
        // approach.
        let buf = calloc(1, Self.totalMessageSize)!
        // Copy the 1-payload skeleton into our 2-payload buffer.
        buf.copyMemory(from: oneShot,
                       byteCount: Self.messageHeaderSize + Self.payloadStride)
        // Replicate payload[0] into payload[1] slot.
        let payload0Start = buf.advanced(by: Self.messageHeaderSize)
        let payload1Start = payload0Start.advanced(by: Self.payloadStride)
        payload1Start.copyMemory(from: payload0Start,
                                 byteCount: Self.payloadStride)
        // Patch finger ratio in payload[0].
        patchDouble(buf, offset: Self.xRatioOffset0, value: Double(ratio.x))
        patchDouble(buf, offset: Self.yRatioOffset0, value: Double(ratio.y))
        // Patch digitizer-summary ratio in payload[1].
        patchDouble(buf, offset: Self.xRatioOffset1, value: Double(ratio.x))
        patchDouble(buf, offset: Self.yRatioOffset1, value: Double(ratio.y))
        // Mark payload[1] as the digitizer summary.
        patchUInt32(buf, offset: Self.p1TouchField1Offset, value: 1)
        patchUInt32(buf, offset: Self.p1TouchField2Offset, value: 2)
        // The builder's one-shot allocation is owned by us; release it
        // since we copied what we needed.
        free(oneShot)

        let sel = NSSelectorFromString(
            "sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard client.responds(to: sel) else {
            free(buf)
            throw SimError(message:
                "SimDeviceLegacyHIDClient missing sendWithMessage: — " +
                "private API drift; see source-of-truth §13 compat matrix.")
        }
        // freeWhenDone:true — SimulatorKit owns the buffer.
        try SimBridge.callSendWithMessage(
            on: client,
            selector: sel,
            message: buf,
            freeWhenDone: true,
        )
    }

    private func makeHidClient() throws -> AnyObject {
        try SimBridge.ensureLoaded()
        // Force SimulatorKit to load so its Swift classes register.
        _ = SimBridge.simulatorKitHandle()
        guard let cls = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient")
            ?? NSClassFromString("SimDeviceLegacyHIDClient") else {
            throw SimError(message:
                "SimDeviceLegacyHIDClient not found — SimulatorKit not loaded?")
        }
        let allocSel = NSSelectorFromString("alloc")
        guard let alloced = (cls as AnyObject).perform(allocSel)?
            .takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "alloc returned nil")
        }
        // -[SimDeviceLegacyHIDClient initWithDevice:error:] — 2 args fits
        // perform(_:with:with:).
        let initSel = NSSelectorFromString("initWithDevice:error:")
        var nsError: NSError? = nil
        let initResult = withUnsafeMutablePointer(to: &nsError) { errPtr in
            return alloced.perform(
                initSel,
                with: device,
                with: NSValue(pointer: UnsafeRawPointer(errPtr)),
            )
        }
        guard let client = initResult?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message:
                "initWithDevice: returned nil — \(nsError?.localizedDescription ?? "no error reported")")
        }
        return client
    }
}

extension SimBridge {
    /// Call -[SimDeviceLegacyHIDClient sendWithMessage:freeWhenDone:completionQueue:completion:]
    /// without going through `perform(_:with:with:)` (which caps at 2 args).
    /// Goes one level lower: dlsym `objc_msgSend`, cast to the actual ObjC
    /// dispatch signature, call it directly. Same pattern Foundation
    /// itself uses on the inside.
    static func callSendWithMessage(
        on receiver: AnyObject,
        selector: Selector,
        message: UnsafeMutableRawPointer,
        freeWhenDone: Bool,
    ) throws {
        // ObjC ABI for the four-arg method:
        //   id self, SEL _cmd, void* msg, BOOL freeWhenDone, id queue, id completion
        typealias SendT = @convention(c) (
            AnyObject, Selector,
            UnsafeMutableRawPointer,
            ObjCBool,
            AnyObject?, AnyObject?,
        ) -> Void
        guard let handle = dlopen(nil, RTLD_LAZY),
              let sym = dlsym(handle, "objc_msgSend") else {
            throw SimError(message: "dlsym(objc_msgSend) failed: " +
                String(cString: dlerror()))
        }
        let send = unsafeBitCast(sym, to: SendT.self)
        send(receiver, selector, message, ObjCBool(freeWhenDone), nil, nil)
    }
}

func hexDump(_ p: UnsafeMutableRawPointer, count: Int) -> String {
    let bytes = p.assumingMemoryBound(to: UInt8.self)
    return (0..<count).map { String(format: "%02x", bytes[$0]) }.joined(separator: " ")
}

func patchDouble(_ buf: UnsafeMutableRawPointer, offset: Int, value: Double) {
    let p = buf.advanced(by: offset).assumingMemoryBound(to: Double.self)
    p.pointee = value
}

func patchUInt32(_ buf: UnsafeMutableRawPointer, offset: Int, value: UInt32) {
    let p = buf.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
    p.pointee = value
}

extension SimBridge {
    /// Handle for the SimulatorKit dlopen, used to dlsym Indigo* C
    /// functions. Caches the handle on first call.
    private static var _simKitHandle: UnsafeMutableRawPointer?

    static func simulatorKitHandle() -> UnsafeMutableRawPointer? {
        if let h = _simKitHandle { return h }
        let devDir = (ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ??
                      "/Applications/Xcode.app/Contents/Developer") as String
        for path in [
            "\(devDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "/Library/Developer/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ] {
            if FileManager.default.fileExists(atPath: path),
               let h = dlopen(path, RTLD_LAZY) {
                _simKitHandle = h
                return h
            }
        }
        return nil
    }
}
