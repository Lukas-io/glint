import Foundation
import Network

struct HttpRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data
}

struct HttpResponse {
    let status: Int
    let json: Any

    static func ok(_ json: Any) -> HttpResponse { HttpResponse(status: 200, json: json) }

    static func error(_ status: Int, _ kind: String, _ detail: String) -> HttpResponse {
        HttpResponse(status: status, json: ["error": kind, "detail": detail])
    }
}

/// A one-request-per-connection HTTP/1.1 server on 127.0.0.1; handlers run on the main thread, where XCUIElement must be used.
final class HttpServer {
    private let listener: NWListener
    private let router: Router
    private let queue = DispatchQueue(label: "glint.runner.http")
    private(set) var stopped = false

    init(port: UInt16, router: Router) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.router = router
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                DispatchQueue.main.async {
                    let response = self.router.handle(request)
                    if request.path == "/shutdown" { self.stopped = true }
                    self.send(response, on: conn)
                }
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func send(_ response: HttpResponse, on conn: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// The request in [buffer] once its headers and Content-Length bytes of body have arrived.
    static func parse(_ buffer: Data) -> HttpRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HttpRequest(
            method: String(parts[0]),
            path: target?.path ?? String(parts[1]),
            query: query,
            body: Data(body.prefix(length)))
    }
}
