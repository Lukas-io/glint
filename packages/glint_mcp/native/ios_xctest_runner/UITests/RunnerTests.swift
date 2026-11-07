import XCTest

/// One test that never finishes on its own: it serves glint's requests until `/shutdown`, until the glint that started it is gone, or until nothing has asked for it in a long while.
final class RunnerTests: XCTestCase {
    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["GLINT_RUNNER_PORT"] ?? "") ?? 22087
        let parent = pid_t(env["GLINT_RUNNER_PARENT_PID"] ?? "")
        let idleLimit = TimeInterval(env["GLINT_RUNNER_IDLE_SECONDS"] ?? "") ?? 5400
        let server = try HttpServer(port: port, router: Router())
        server.start()
        while !server.stopped {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let parent, kill(parent, 0) != 0, errno == ESRCH { break }
            if Date().timeIntervalSince(server.lastRequestAt) > idleLimit { break }
        }
    }
}
