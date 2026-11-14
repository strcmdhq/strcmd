import Foundation

enum DropScope: Sendable {
    case connection
    case forward(UUID)
    // The forward is still up but has a problem to show, or an empty reason to clear it.
    case forwardNotice(UUID)
}

typealias DropHandler = @Sendable (DropScope, String) -> Void
typealias SessionLogHandler = @Sendable (LogEntry.Level, String) -> Void

protocol ForwardSession: Actor {
    nonisolated var identity: String { get }
    var activeForwardIDs: Set<UUID> { get async }
    func connect(onDrop: @escaping DropHandler) async throws
    func probe() async -> TimeInterval?
    func apply(desired: [PortForward]) async -> [UUID: String]
    func disconnect() async
}

func timedProbe(_ succeeded: () async -> Bool) async -> TimeInterval? {
    let start = ContinuousClock.now
    guard await succeeded() else { return nil }
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

func makeSession(for connection: Connection, registry: ProcessRegistry, log: @escaping SessionLogHandler) -> any ForwardSession {
    switch connection.kind {
    case .ssh: SSHSession(connection: connection, registry: registry, log: log)
    case .kubernetes: KubeSession(connection: connection, registry: registry, log: log)
    case .awsSSM: AWSSession(connection: connection, registry: registry, log: log)
    }
}
