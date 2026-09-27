import Foundation

/// How the bridge picks its input transport, from `--hid`.
enum HidMode: String, CaseIterable {
    case auto, dtuhid, indigo
}

enum TouchPhase {
    case start, move, end
}

/// One open input transport; [finish] must run before the process exits so queued events reach the guest.
protocol HidInput {
    var name: String { get }
    func touch(_ ratio: CGPoint, _ phase: TouchPhase) throws
    func key(_ usage: Int32, down: Bool) throws
    func finish()
}

/// The legacy SimulatorKit path; the guest drops its touch and keys once `dtuhidd` is active for the boot.
struct IndigoInput: HidInput {
    let proxy: SimDeviceProxy
    let client: AnyObject

    var name: String { "indigo" }

    func touch(_ ratio: CGPoint, _ phase: TouchPhase) throws {
        switch phase {
        case .start: try proxy.sendTouch(client: client, ratio: ratio, direction: .down, marker: .start)
        case .move: try proxy.sendTouch(client: client, ratio: ratio, direction: .down, marker: .move)
        case .end: try proxy.sendTouch(client: client, ratio: ratio, direction: .up, marker: .end)
        }
    }

    func key(_ usage: Int32, down: Bool) throws {
        try proxy.sendKey(client: client, usage: usage, direction: down ? .down : .up)
    }

    func finish() {}
}

/// Touch and keys over `dtuhidd` (CoreSimulator 1155.4+).
struct DtuHidInput: HidInput {
    let connection: DtuHidConnection

    var name: String { "dtuhid" }

    func touch(_ ratio: CGPoint, _ phase: TouchPhase) throws {
        switch phase {
        case .start: connection.touch(ratio: ratio, phase: 0)
        case .move: connection.touch(ratio: ratio, phase: 1)
        case .end: connection.touch(ratio: ratio, phase: 2)
        }
    }

    func key(_ usage: Int32, down: Bool) throws {
        connection.key(usage: usage, down: down)
    }

    func finish() {
        connection.drain()
        connection.cancel()
    }
}
