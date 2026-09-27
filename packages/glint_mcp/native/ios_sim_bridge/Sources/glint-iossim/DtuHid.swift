// Wire format and connect path follow idb's DTUHID transport (MIT, Copyright (c) Meta Platforms, Inc.).

import Foundation
import XPC

/// Keyboard and touch input through `dtuhidd`, the HID service CoreSimulator 1155.4+ (Xcode 27) injects into the guest.
struct DtuHidConnection {
    static let digitizerService = "com.apple.coredevice.feature.remote.hid.digitizer"
    static let firstCoreSimulatorVersion = "1155.4"

    private static let livenessTimeout = 4.0
    private static let livenessAttempts = 2
    private static let livenessBackoff = 1.0
    private static let drainSeconds = 0.08

    private let connection: xpc_connection_t
    private let queue: DispatchQueue
    let serviceName: String

    /// CFBundleVersion of the CoreSimulator framework loaded in this process, e.g. `1171.7`.
    static var loadedCoreSimulatorVersion: String? {
        guard let cls = NSClassFromString("SimDevice") else { return nil }
        return Bundle(for: cls).infoDictionary?["CFBundleVersion"] as? String
    }

    /// True when the loaded CoreSimulator ships `dtuhidd`; compared numerically so 1155.10 sorts above 1155.4.
    static var shipped: Bool {
        guard let v = loadedCoreSimulatorVersion else { return false }
        return v.compare(firstCoreSimulatorVersion, options: .numeric) != .orderedAscending
    }

    /// Connects to [service] on [device] and proves `dtuhidd` answers before returning.
    static func connect(device: AnyObject, service: String = digitizerService) throws -> DtuHidConnection {
        var last: Error = SimError(message: "dtuhidd did not answer")
        for attempt in 1...livenessAttempts {
            let conn = try DtuHidConnection(device: device, service: service)
            do {
                try conn.confirmLiveness()
                return conn
            } catch {
                conn.cancel()
                last = error
                if attempt < livenessAttempts { Thread.sleep(forTimeInterval: livenessBackoff) }
            }
        }
        throw SimError(message:
            "dtuhidd did not answer \(livenessAttempts) liveness probes on \(service): \(last.localizedDescription)")
    }

    private init(device: AnyObject, service: String) throws {
        serviceName = service
        queue = DispatchQueue(label: "glint.dtuhid")
        connection = try Self.open(device: device, service: service)
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    private typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
    private typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
    private typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void
    private typealias Lookup = @convention(c) (
        AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> mach_port_t

    private static func open(device: AnyObject, service: String) throws -> xpc_connection_t {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            throw SimError(message: "dlopen(nil) failed")
        }
        defer { dlclose(handle) }
        guard let e = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let c = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let s = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            throw SimError(message: "the simulator XPC symbols are missing from libxpc")
        }
        let port = try lookup(device: device, service: service)
        guard let endpoint = unsafeBitCast(e, to: EndpointFromPort.self)(port, 0, 0)?
                .takeRetainedValue() as? xpc_object_t,
              let conn = unsafeBitCast(c, to: ConnectionFromEndpoint.self)(endpoint)?
                .takeRetainedValue() as? xpc_connection_t else {
            throw SimError(message: "could not open an XPC connection to \(service)")
        }
        unsafeBitCast(s, to: EnableSim2Host.self)(conn)
        return conn
    }

    private static func lookup(device: AnyObject, service: String) throws -> mach_port_t {
        let sel = NSSelectorFromString("lookup:error:")
        guard let cls = object_getClass(device),
              let method = class_getInstanceMethod(cls, sel) else {
            throw SimError(message: "SimDevice has no lookup:error: (private API drift)")
        }
        var error: NSError?
        let port = unsafeBitCast(method_getImplementation(method), to: Lookup.self)(
            device, sel, service as NSString, &error)
        guard port != MACH_PORT_NULL else {
            throw SimError(message:
                "the simulator has no \(service) service: " + (error?.localizedDescription ?? "lookup returned no port"))
        }
        return port
    }

    private func confirmLiveness() throws {
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        xpc_connection_send_message_with_reply(connection, message(
            type: "IndigoKeyboardButtonEvent", payload: keyPayload(usage: 0, down: false), barrier: true
        ), queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                failure = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                    .map { String(cString: $0) } ?? "XPC error"
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.livenessTimeout) == .success else {
            throw SimError(message: "no reply within \(Int(Self.livenessTimeout))s")
        }
        if let failure { throw SimError(message: failure) }
    }

    /// Sends one key transition for HID keyboard [usage].
    func key(usage: Int32, down: Bool) {
        send(type: "IndigoKeyboardButtonEvent", payload: keyPayload(usage: usage, down: down))
    }

    /// Sends one transition of the hardware button with HID Consumer-page [usage].
    func button(usage: UInt64, down: Bool) {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", 0x0C)
        xpc_dictionary_set_uint64(payload, "usageCode", usage)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        send(type: "IndigoButtonEvent", payload: payload)
    }

    /// Sends one digitizer frame at [ratio] (0...1 of the screen); phase 0 = start, 1 = move, 2 = end.
    func touch(ratio: CGPoint, phase: UInt64) {
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", Double(ratio.x))
        xpc_dictionary_set_double(point, "y", Double(ratio.y))
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "pointOne", point)
        xpc_dictionary_set_uint64(payload, "eventType", phase)
        xpc_dictionary_set_uint64(payload, "edge", 0)
        xpc_dictionary_set_uint64(payload, "target", 0)
        send(type: "IndigoDigitizerEvent", payload: payload)
    }

    /// Waits until every queued event has left this process, then gives `dtuhidd` time to deliver it to the guest.
    func drain() {
        let done = DispatchSemaphore(value: 0)
        xpc_connection_send_barrier(connection) { done.signal() }
        _ = done.wait(timeout: .now() + 2)
        Thread.sleep(forTimeInterval: Self.drainSeconds)
    }

    func cancel() {
        xpc_connection_cancel(connection)
    }

    private func send(type: String, payload: xpc_object_t) {
        xpc_connection_send_message(connection, message(type: type, payload: payload, barrier: false))
    }

    private func keyPayload(usage: Int32, down: Bool) -> xpc_object_t {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        return payload
    }

    private func message(type: String, payload: xpc_object_t, barrier: Bool) -> xpc_object_t {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "messageType", type)
        xpc_dictionary_set_bool(m, "isBarrier", barrier)
        xpc_dictionary_set_string(m, "featureIdentifier", serviceName)
        xpc_dictionary_set_value(m, "payload", payload)
        return m
    }
}
