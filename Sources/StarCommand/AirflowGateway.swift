import Foundation
import Network

// Managed Airflow only signs in on its own hostname, so the local port hands the browser a fresh login link instead of tunnelling.
final class AirflowGateway: @unchecked Sendable {
    enum State: Equatable { case stopped, listening, failed(String) }

    typealias Mint = @Sendable () async -> Result<URL, ToolError>

    let port: UInt16
    private let mint: Mint
    private let onState: @Sendable (State) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.strcmd.starcommand.airflow")

    init(port: UInt16, mint: @escaping Mint, onState: @escaping @Sendable (State) -> Void) {
        self.port = port
        self.mint = mint
        self.onState = onState
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, onState] state in
                switch state {
                case .ready: onState(.listening)
                case .failed(let error):
                    onState(.failed(Self.describe(error)))
                    self?.stop()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState(.failed(Self.describe(error)))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let request = Self.parse(data ?? Data())
            guard let request, Self.isAllowedHost(request.host, port: self.port) else {
                return Self.reply(connection, Self.response(403, "Forbidden"))
            }
            guard request.method == "GET", request.path == "/" || request.path.hasPrefix("/?") else {
                return Self.reply(connection, Self.response(404, "Not found"))
            }
            Task {
                switch await self.mint() {
                case .success(let url): Self.reply(connection, Self.redirect(url))
                case .failure(let error): Self.reply(connection, Self.response(502, error.message))
                }
            }
        }
    }

    struct Request: Equatable {
        let method: String
        let path: String
        let host: String?
    }

    static func parse(_ data: Data) -> Request? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        return Request(method: String(parts[0]), path: String(parts[1]), host: host)
    }

    // Rejecting other Host headers stops a DNS-rebinding page from reaching the login link.
    static func isAllowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost:\(port)", "127.0.0.1:\(port)"].contains(host)
    }

    static func redirect(_ url: URL) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(url.absoluteString)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    static func response(_ status: Int, _ message: String) -> String {
        let reason = [403: "Forbidden", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let body = "<!doctype html><meta charset=utf-8><title>Star Command</title><body style=\"font:15px -apple-system;margin:3em\"><p>\(escaped)</p></body>"
        return "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func reply(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func describe(_ error: Error) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE { return "Address already in use" }
        return error.localizedDescription
    }
}
