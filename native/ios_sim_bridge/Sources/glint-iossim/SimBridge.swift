// SimBridge.swift — drives iOS Simulator HID input via private
// CoreSimulator + SimulatorKit. Per-Xcode mapping lives in
// source-of-truth §13 compat matrix; the Xcode-26 path goes through
// `SimulatorKit.SimDeviceLegacyHIDClient.sendWithMessage:...` carrying
// an IndigoHIDMessageStruct built by SimulatorKit's exported C builders
// (IndigoHIDMessageForMouseNSEvent / IndigoHIDMessageForButton /
// IndigoHIDMessageForKeyboardArbitrary).

import Foundation

struct SimError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BootedDevice {
    let udid: String
    let name: String
}

/// 1 = key/touch down, 2 = key/touch up. Same encoding for mouse, button,
/// and keyboard `op` args in SimulatorKit's IndigoHID builders.
enum TouchDirection: Int32 {
    case down = 1
    case up = 2
}

/// Display target hardcoded since idb's Xcode 14 path; survives unchanged
/// through Xcode 26 for mouse/touch events. `IndigoHIDTargetForScreen`
/// would supersede this for hardware-button work — see §13.
enum IndigoTarget {
    static let defaultDisplay: Int32 = 0x32
}

enum SimBridge {
    private static var loaded = false

    static func ensureLoaded() throws {
        if loaded { return }
        let devDir = developerDir() as String
        let frameworks = [
            "\(devDir)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(devDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            // Fallback: pre-Xcode-15 installs put CoreSimulator under /Library.
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
        let devices = try _allDevices()
        var out: [BootedDevice] = []
        for d in devices where _deviceState(d) == .booted {
            out.append(BootedDevice(
                udid: _deviceUdid(d),
                name: _deviceName(d),
            ))
        }
        return out
    }

    static func requireBootedDevice(udid: String) throws -> SimDeviceProxy {
        try ensureLoaded()
        let target = udid.uppercased()
        for d in try _allDevices() where _deviceUdid(d).uppercased() == target {
            return SimDeviceProxy(device: d)
        }
        throw SimError(message: "no SimDevice with UDID \(udid)")
    }

    /// CoreSimulator's SimDeviceState enum.
    enum DeviceState: Int {
        case creating = 0
        case shutdown = 1
        case booting = 2
        case booted = 3
        case shuttingDown = 4
        case unknown = -1
    }

    private static func _allDevices() throws -> [AnyObject] {
        guard let SimServiceContext = NSClassFromString("SimServiceContext") else {
            throw SimError(message: "SimServiceContext class not found")
        }
        guard let ctx = (SimServiceContext as AnyObject).perform(
            NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
            with: developerDir(),
            with: NSNull(),
        )?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "sharedServiceContextForDeveloperDir returned nil")
        }
        guard let set = ctx.perform(
            NSSelectorFromString("defaultDeviceSetWithError:"), with: NSNull(),
        )?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "defaultDeviceSetWithError returned nil")
        }
        guard let devices = set.perform(NSSelectorFromString("devices"))?
            .takeUnretainedValue() as? [AnyObject] else {
            throw SimError(message: "devices returned nil")
        }
        return devices
    }

    private static func _deviceState(_ d: AnyObject) -> DeviceState {
        let raw = ((d as? NSObject)?.value(forKey: "state") as? NSNumber)?.intValue ?? -1
        return DeviceState(rawValue: raw) ?? .unknown
    }

    private static func _deviceUdid(_ d: AnyObject) -> String {
        ((d as? NSObject)?.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
    }

    private static func _deviceName(_ d: AnyObject) -> String {
        ((d as? NSObject)?.value(forKey: "name") as? String) ?? ""
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
            let s = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8,
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s as NSString
        } catch {
            return "/Applications/Xcode.app/Contents/Developer" as NSString
        }
    }

    static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[glint-iossim] \(msg)\n".utf8))
    }

    // MARK: - Reverse-engineering helpers
    //
    // Used by the dump-* and probe-* CLI commands. Output goes to stdout
    // so the human running the probe can grep / pipe it.

    static func dumpProtocols(matching needles: [String]) {
        var count: UInt32 = 0
        guard let list = objc_copyProtocolList(&count) else {
            print("no protocols")
            return
        }
        let lower = needles.map { $0.lowercased() }
        for i in 0..<Int(count) {
            let p: Protocol = list[i]
            let name = String(cString: protocol_getName(p))
            guard lower.contains(where: { name.lowercased().contains($0) }) else { continue }
            print("\n## protocol \(name) ##")
            // post-Swift-5.9 method_description name/types are optionals
            for (req, inst) in [(true, true), (true, false), (false, true), (false, false)] {
                var mcount: UInt32 = 0
                guard let methods = protocol_copyMethodDescriptionList(p, req, inst, &mcount)
                else { continue }
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
            var pcount: UInt32 = 0
            if let adopted = protocol_copyProtocolList(p, &pcount), pcount > 0 {
                let names = (0..<Int(pcount)).map {
                    String(cString: protocol_getName(adopted[$0]))
                }
                print("  conforms-to: \(names.joined(separator: ", "))")
                free(UnsafeMutableRawPointer(adopted))
            }
        }
        free(UnsafeMutableRawPointer(list))
    }

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
        let lower = needles.map { $0.lowercased() }
        var matched = 0
        for i in 0..<n {
            let name = NSStringFromClass(buf[i])
            if lower.contains(where: { name.lowercased().contains($0) }) {
                print("- \(name)")
                matched += 1
            }
        }
        print("(\(matched) classes matched; \(n) total registered)")
    }

    static func dumpAllMethods(of cls: AnyClass) {
        var c: AnyClass? = cls
        while let cur = c {
            let name = NSStringFromClass(cur)
            print("== \(name) ==")
            var pcount: UInt32 = 0
            if let protos = class_copyProtocolList(cur, &pcount), pcount > 0 {
                let names = (0..<Int(pcount)).map {
                    String(cString: protocol_getName(protos[$0]))
                }
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
                        let types = method_getTypeEncoding(m).map {
                            String(cString: $0)
                        } ?? "<?>"
                        print("  \(prefix)[\(name) \(sel)]  types=\(types)")
                    }
                    free(methods)
                }
            }
            c = class_getSuperclass(cur)
            if c == NSObject.self { break }
        }
    }

    static func dumpDeviceMethods(of device: AnyObject, matching needles: [String]) {
        var cls: AnyClass? = object_getClass(device)
        let lower = needles.map { $0.lowercased() }
        while let c = cls {
            print("== \(NSStringFromClass(c)) ==")
            var count: UInt32 = 0
            if let methods = class_copyMethodList(c, &count) {
                for i in 0..<Int(count) {
                    let m = methods[i]
                    let name = NSStringFromSelector(method_getName(m)).lowercased()
                    if lower.contains(where: { name.contains($0) }) {
                        let types = String(cString: method_getTypeEncoding(m)!)
                        print(
                            "  -[\(NSStringFromClass(c))" +
                            " \(NSStringFromSelector(method_getName(m)))]" +
                            "  types=\(types)",
                        )
                    }
                }
                free(methods)
            }
            cls = class_getSuperclass(c)
            if cls == NSObject.self { break }
        }
    }
}

/// Drives one booted SimDevice's HID stream.
struct SimDeviceProxy {
    let device: AnyObject

    func tap(x: Double, y: Double, deviceLogicalSize: CGSize) throws {
        let ratio = _ratio(x: x, y: y, in: deviceLogicalSize)
        let client = try makeHidClient()
        try sendTouch(client: client, ratio: ratio, direction: .down)
        // ~50ms dwell so the OS recognises a tap (idb's value).
        Thread.sleep(forTimeInterval: 0.05)
        try sendTouch(client: client, ratio: ratio, direction: .up)
    }

    func longPress(
        x: Double,
        y: Double,
        deviceLogicalSize: CGSize,
        durationMs: Int,
    ) throws {
        let ratio = _ratio(x: x, y: y, in: deviceLogicalSize)
        let client = try makeHidClient()
        try sendTouch(client: client, ratio: ratio, direction: .down)
        Thread.sleep(forTimeInterval: Double(durationMs) / 1000.0)
        try sendTouch(client: client, ratio: ratio, direction: .up)
    }

    func swipe(
        from: CGPoint,
        to: CGPoint,
        deviceLogicalSize: CGSize,
        durationMs: Int,
    ) throws {
        let steps = max(8, durationMs / 16)
        let perStepMs = max(1, durationMs / steps)
        let client = try makeHidClient()
        let r1 = _ratio(x: from.x, y: from.y, in: deviceLogicalSize)
        let r2 = _ratio(x: to.x, y: to.y, in: deviceLogicalSize)
        try sendTouch(client: client, ratio: r1, direction: .down, marker: .start)
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            let r = CGPoint(
                x: r1.x + (r2.x - r1.x) * t,
                y: r1.y + (r2.y - r1.y) * t,
            )
            try sendTouch(client: client, ratio: r, direction: .down, marker: .move)
            Thread.sleep(forTimeInterval: Double(perStepMs) / 1000.0)
        }
        try sendTouch(client: client, ratio: r2, direction: .up, marker: .end)
    }

    func pressButton(_ buttonCode: Int32) throws {
        let client = try makeHidClient()
        try sendButton(client: client, code: buttonCode, direction: .down)
        Thread.sleep(forTimeInterval: 0.05)
        try sendButton(client: client, code: buttonCode, direction: .up)
    }

    /// Sends literal ASCII text via per-character HID key down/up. Shifted
    /// characters bracket the key with shift-down / shift-up.
    func typeText(_ text: String) throws {
        let client = try makeHidClient()
        for scalar in text.unicodeScalars {
            guard let m = HidKeymap.map(scalar) else {
                throw SimError(message:
                    "no HID mapping for U+\(String(scalar.value, radix: 16, uppercase: true))" +
                    " — v1 keyboard supports ASCII printable + space/newline/tab/backspace")
            }
            if m.shift {
                try sendKey(client: client, usage: HidKeymap.shiftUsage, direction: .down)
            }
            try sendKey(client: client, usage: m.usage, direction: .down)
            // ~5ms dwell — modern simulators register on the down edge but
            // some IMEs need the up to commit.
            Thread.sleep(forTimeInterval: 0.005)
            try sendKey(client: client, usage: m.usage, direction: .up)
            if m.shift {
                try sendKey(client: client, usage: HidKeymap.shiftUsage, direction: .up)
            }
        }
    }

    private func _ratio(x: CGFloat, y: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(x: x / size.width, y: y / size.height)
    }

    private func _ratio(x: Double, y: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) / size.width, y: CGFloat(y) / size.height)
    }

    private func sendTouch(
        client: AnyObject,
        ratio: CGPoint,
        direction: TouchDirection,
        marker: DigitizerMarker = .start,
    ) throws {
        let buf = try IndigoTouchMessage(
            ratio: ratio,
            direction: direction,
            marker: marker,
        ).buffer
        try send(client: client, message: buf)
    }

    private func sendButton(
        client: AnyObject,
        code: Int32,
        direction: TouchDirection,
    ) throws {
        let buf = try _buildVia(
            symbol: "IndigoHIDMessageForButton",
            buildSignature: ButtonBuilder.self,
        ).build(code, direction.rawValue, IndigoTarget.defaultDisplay)
        guard let buf else {
            throw SimError(message:
                "IndigoHIDMessageForButton returned nil for code \(code)")
        }
        try send(client: client, message: buf)
    }

    private func sendKey(
        client: AnyObject,
        usage: Int32,
        direction: TouchDirection,
    ) throws {
        let buf = try _buildVia(
            symbol: "IndigoHIDMessageForKeyboardArbitrary",
            buildSignature: KeyBuilder.self,
        ).build(usage, direction.rawValue)
        guard let buf else {
            throw SimError(message:
                "IndigoHIDMessageForKeyboardArbitrary returned nil for usage \(usage)")
        }
        try send(client: client, message: buf)
    }

    private func send(client: AnyObject, message: UnsafeMutableRawPointer) throws {
        let sel = NSSelectorFromString(
            "sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard client.responds(to: sel) else {
            free(message)
            throw SimError(message:
                "SimDeviceLegacyHIDClient missing sendWithMessage: — " +
                "private API drift; see source-of-truth §13 compat matrix.")
        }
        // freeWhenDone:true hands ownership to SimulatorKit.
        try SimBridge.callSendWithMessage(
            on: client,
            selector: sel,
            message: message,
            freeWhenDone: true,
        )
    }

    private func makeHidClient() throws -> AnyObject {
        try SimBridge.ensureLoaded()
        _ = SimBridge.simulatorKitHandle()
        guard let cls = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient")
            ?? NSClassFromString("SimDeviceLegacyHIDClient") else {
            throw SimError(message:
                "SimDeviceLegacyHIDClient not found — SimulatorKit not loaded?")
        }
        guard let alloced = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue() as AnyObject? else {
            throw SimError(message: "alloc returned nil")
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        var nsError: NSError? = nil
        let initResult = withUnsafeMutablePointer(to: &nsError) { errPtr in
            alloced.perform(
                initSel,
                with: device,
                with: NSValue(pointer: UnsafeRawPointer(errPtr)),
            )
        }
        guard let client = initResult?.takeUnretainedValue() as AnyObject? else {
            throw SimError(message:
                "initWithDevice: returned nil — " +
                (nsError?.localizedDescription ?? "no error reported"))
        }
        return client
    }

    private typealias ButtonBuilder = @convention(c) (
        Int32,  // keyCode
        Int32,  // op
        Int32,  // target
    ) -> UnsafeMutableRawPointer?

    private typealias KeyBuilder = @convention(c) (
        Int32,  // keyCode
        Int32,  // op
    ) -> UnsafeMutableRawPointer?

    private struct _Builder<F> {
        let build: F
    }

    private func _buildVia<F>(
        symbol: String,
        buildSignature: F.Type,
    ) throws -> _Builder<F> {
        guard let sym = dlsym(SimBridge.simulatorKitHandle(), symbol) else {
            throw SimError(message:
                "dlsym(\(symbol)) failed: " + String(cString: dlerror()))
        }
        return _Builder(build: unsafeBitCast(sym, to: F.self))
    }
}

/// Distinguishes start / move / end frames for a swipe so the simulator
/// hit-test reads them as a continuous drag rather than discrete taps.
enum DigitizerMarker {
    case start, move, end

    /// `(field1, field2)` written into payload[1]'s touch event.
    /// Values empirically derived from idb's Xcode-14 markers + a
    /// move-marker delta this glint maintains in §13.
    var fields: (UInt32, UInt32) {
        switch self {
        case .start: return (1, 2)
        case .move:  return (2, 2)
        case .end:   return (1, 2)
        }
    }
}

/// Builds the Xcode-26 IndigoHIDMessageStruct for one touch frame.
///
/// Layout (verified by hex-dumping the builder output):
///   0x00..0x17  outer envelope (zero)
///   0x18        innerSize = 0xA0
///   0x1C        eventType = 2 (touch)
///   0x20..0xBF  payload[0] (finger)
///     0x3C       touch.xRatio (double)
///     0x44       touch.yRatio (double)
///   0xC0..0x15F payload[1] (digitizer summary — mirrors payload[0])
///     0xCC       touch.field1 (varies by DigitizerMarker)
///     0xD0       touch.field2 (varies by DigitizerMarker)
///     0xDC       touch.xRatio
///     0xE4       touch.yRatio
///   total = 0x160 (352) bytes
private struct IndigoTouchMessage {
    enum Layout {
        static let payloadStride = 0xA0
        static let headerSize = 0x20
        static let totalSize = headerSize + 2 * payloadStride
        static let xRatio0 = 0x3C
        static let yRatio0 = 0x44
        static let xRatio1 = 0xDC
        static let yRatio1 = 0xE4
        static let p1Field1 = 0xCC
        static let p1Field2 = 0xD0
    }

    let ratio: CGPoint
    let direction: TouchDirection
    let marker: DigitizerMarker

    /// Allocated buffer ready to hand to SimulatorKit (freeWhenDone:true).
    var buffer: UnsafeMutableRawPointer {
        get throws {
            guard let sym = dlsym(
                SimBridge.simulatorKitHandle(),
                "IndigoHIDMessageForMouseNSEvent",
            ) else {
                throw SimError(message:
                    "dlsym(IndigoHIDMessageForMouseNSEvent) failed: " +
                    String(cString: dlerror()))
            }
            typealias Builder = @convention(c) (
                UnsafePointer<CGPoint>,
                UnsafePointer<CGPoint>?,
                Int32,
                Int32,
                DarwinBoolean,
            ) -> UnsafeMutableRawPointer?
            let build = unsafeBitCast(sym, to: Builder.self)
            var point = ratio
            guard let oneShot = build(
                &point,
                nil,
                IndigoTarget.defaultDisplay,
                direction.rawValue,
                DarwinBoolean(false),
            ) else {
                throw SimError(message:
                    "IndigoHIDMessageForMouseNSEvent returned nil for " +
                    "(\(ratio.x), \(ratio.y))")
            }
            defer { free(oneShot) }

            // Build the 2-payload structure: copy header+payload[0] from
            // the one-shot, then replicate payload[0] → payload[1], then
            // patch ratios and the digitizer-summary markers.
            let buf = calloc(1, Layout.totalSize)!
            buf.copyMemory(
                from: oneShot,
                byteCount: Layout.headerSize + Layout.payloadStride,
            )
            let p0 = buf.advanced(by: Layout.headerSize)
            let p1 = p0.advanced(by: Layout.payloadStride)
            p1.copyMemory(from: p0, byteCount: Layout.payloadStride)

            _writeDouble(buf, at: Layout.xRatio0, value: Double(ratio.x))
            _writeDouble(buf, at: Layout.yRatio0, value: Double(ratio.y))
            _writeDouble(buf, at: Layout.xRatio1, value: Double(ratio.x))
            _writeDouble(buf, at: Layout.yRatio1, value: Double(ratio.y))

            let (f1, f2) = marker.fields
            _writeUInt32(buf, at: Layout.p1Field1, value: f1)
            _writeUInt32(buf, at: Layout.p1Field2, value: f2)
            return buf
        }
    }
}

private func _writeDouble(
    _ buf: UnsafeMutableRawPointer,
    at offset: Int,
    value: Double,
) {
    buf.advanced(by: offset).assumingMemoryBound(to: Double.self).pointee = value
}

private func _writeUInt32(
    _ buf: UnsafeMutableRawPointer,
    at offset: Int,
    value: UInt32,
) {
    buf.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee = value
}

extension SimBridge {
    /// `sendWithMessage:freeWhenDone:completionQueue:completion:` takes 4
    /// args, exceeding Swift's `perform(_:with:with:)`. We drop to
    /// objc_msgSend with a typed cast — same shape Foundation uses internally.
    static func callSendWithMessage(
        on receiver: AnyObject,
        selector: Selector,
        message: UnsafeMutableRawPointer,
        freeWhenDone: Bool,
    ) throws {
        typealias SendT = @convention(c) (
            AnyObject, Selector,
            UnsafeMutableRawPointer,
            ObjCBool,
            AnyObject?, AnyObject?,
        ) -> Void
        guard let handle = dlopen(nil, RTLD_LAZY),
              let sym = dlsym(handle, "objc_msgSend") else {
            throw SimError(message:
                "dlsym(objc_msgSend) failed: " + String(cString: dlerror()))
        }
        let send = unsafeBitCast(sym, to: SendT.self)
        send(receiver, selector, message, ObjCBool(freeWhenDone), nil, nil)
    }

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
