import Foundation
import Network

/// Serves numbered test pages on 127.0.0.1, so the smoke tests need no network and load no real site.
/// `/a` is a page titled "Page a" whose heading reads "Fir test page a".
final class PageServer: @unchecked Sendable {
    static let shared = try! PageServer()

    private let listener: NWListener
    let port: UInt16

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { Self.serve($0) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func url(_ page: String) -> String { "http://127.0.0.1:\(port)/\(page)" }

    private static func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Long enough to scroll, so the bar can collapse as on a real page.
            let body = """
                <!doctype html><html><head><meta name="viewport" content="width=device-width">
                <title>Page \(name)</title></head>
                <body><h1>Fir test page \(name)</h1>\(String(repeating: "<p>Line of text.</p>", count: 80))</body></html>
                """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
