import XCTest

/// One test that never finishes on its own: it serves glint's requests until `/shutdown`.
final class RunnerTests: XCTestCase {
    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["GLINT_RUNNER_PORT"] ?? "") ?? 22087
        let server = try HttpServer(port: port, router: Router())
        server.start()
        while !server.stopped {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
