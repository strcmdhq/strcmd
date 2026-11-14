import AppKit
import Combine
import Network

@MainActor
final class ConnectionManager: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var wanted: Set<UUID> = [] {
        didSet { hasWantedConnections = !wanted.isEmpty }
    }
    @Published private(set) var hasWantedConnections = false
    @Published private(set) var activeForwards: [UUID: Set<UUID>] = [:]
    @Published private(set) var forwardErrors: [UUID: String] = [:]
    @Published private(set) var latency: [UUID: TimeInterval] = [:]

    private let store: ConfigStore
    private let notifier: Notifier
    private let log: LogStore
    private let registry = ProcessRegistry()
    private var sessions: [UUID: any ForwardSession] = [:]
    private var connectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var forwardRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var latencyTasks: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: Int] = [:]
    private var forwardAttempts: [UUID: Int] = [:]
    private var recheckTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []

    init(store: ConfigStore, settings: AppSettings? = nil, log: LogStore? = nil) {
        self.store = store
        notifier = Notifier(settings: settings ?? AppSettings())
        self.log = log ?? LogStore()

        store.$connections
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] connections in Task { await self?.reconcile(connections) } }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRecheck(after: 3) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.registry.terminateAll()
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [registry] in
                registry.terminateAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.scheduleRecheck(after: 2) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.strcmd.starcommand.path"))

        for connection in store.connections where connection.connectOnLaunch {
            Task { await setWanted(connection.id, true) }
        }
    }

    func status(_ id: UUID) -> Status {
        statuses[id] ?? .disconnected
    }

    var anyConnected: Bool {
        statuses.values.contains(.connected)
    }

    var menuState: MenuGlyph.State {
        if anyConnected { return .connected }
        if wanted.contains(where: { if case .failed = status($0) { true } else { false } }) { return .failed }
        return .idle
    }

    static func latencyText(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    func isActive(_ forwardID: UUID, in connectionID: UUID) -> Bool {
        activeForwards[connectionID]?.contains(forwardID) ?? false
    }

    func setWanted(_ id: UUID, _ on: Bool) async {
        if on {
            wanted.insert(id)
            attempts[id] = 0
            await connect(id)
        } else {
            wanted.remove(id)
            notifier.forget(id)
            cancelRetries(id)
            await disconnect(id)
        }
    }

    func setForwardEnabled(_ connectionID: UUID, _ forwardID: UUID, _ enabled: Bool) {
        store.update(connectionID) { connection in
            guard let index = connection.forwards.firstIndex(where: { $0.id == forwardID }) else { return }
            connection.forwards[index].enabled = enabled
        }
    }

    func disconnectAll() async {
        for id in wanted {
            await setWanted(id, false)
        }
    }

    func reconnect(_ id: UUID) async {
        guard wanted.contains(id), statuses[id] != .connecting else { return }
        cancelRetries(id)
        attempts[id] = 0
        forwardAttempts[id] = 0
        statuses[id] = .connecting
        log.append(id, .info, "Reconnect requested")
        if let connection = store.connection(id), connection.kind == .awsSSM {
            await SSOLogin.shared.forgive(connection.awsProfile)
        }
        await connectFresh(id)
    }

    func retryForwards(_ id: UUID) async {
        forwardRetryTasks[id]?.cancel()
        forwardRetryTasks[id] = nil
        forwardAttempts[id] = 0
        guard statuses[id] == .connected else { return }
        log.append(id, .info, "Forward retry requested")
        await applyForwards(id)
    }

    private func connect(_ id: UUID) async {
        if let running = connectTasks[id] {
            await running.value
            return
        }
        let task = Task { await performConnect(id) }
        connectTasks[id] = task
        await task.value
        if connectTasks[id] == task { connectTasks[id] = nil }
    }

    private func performConnect(_ id: UUID) async {
        guard let connection = store.connection(id) else { return }
        if let existing = sessions[id] {
            if statuses[id] == .connected, await probe(id, existing) != nil { return }
            stopLatencyProbes(id)
            sessions[id] = nil
            await existing.disconnect()
        }

        statuses[id] = .connecting
        log.append(id, .info, "Connecting")
        let session = makeSession(for: connection, registry: registry, log: log.handler(for: id))
        sessions[id] = session
        do {
            try await session.connect { [weak self] scope, reason in
                Task { @MainActor in self?.dropped(id, session: session, scope: scope, reason: reason) }
            }
            guard sessions[id] === session else { return }
            statuses[id] = .connected
            attempts[id] = 0
            log.append(id, .info, "Connected")
            if let connection = store.connection(id) { notifier.recovered(connection) }
            startLatencyProbes(id, session)
            await applyForwards(id)
        } catch {
            guard sessions[id] === session else { return }
            sessions[id] = nil
            statuses[id] = .failed(error.localizedDescription)
            log.append(id, .error, "Connect failed: \(error.localizedDescription)")
            scheduleReconnect(id)
        }
    }

    private func disconnect(_ id: UUID) async {
        if let previous = statuses[id], previous != .disconnected { log.append(id, .info, "Disconnected") }
        statuses[id] = .disconnected
        activeForwards[id] = nil
        clearForwardErrors(id)
        stopLatencyProbes(id)
        guard let session = sessions[id] else { return }
        sessions[id] = nil
        await session.disconnect()
    }

    private func dropped(_ id: UUID, session: any ForwardSession, scope: DropScope, reason: String) {
        guard sessions[id] === session else { return }
        switch scope {
        case .connection:
            guard statuses[id] != .connecting else { return }
            sessions[id] = nil
            activeForwards[id] = nil
            clearForwardErrors(id)
            stopLatencyProbes(id)
            noteDrop(id, reason: reason)
            statuses[id] = .failed(reason)
            scheduleReconnect(id)
        case .forward(let forwardID):
            activeForwards[id]?.remove(forwardID)
            forwardErrors[forwardID] = reason
            log.append(id, .error, "Forward \(forwardName(id, forwardID)) dropped: \(reason)")
            scheduleForwardRetry(id)
        case .forwardNotice(let forwardID):
            guard forwardErrors[forwardID] != (reason.isEmpty ? nil : reason) else { return }
            forwardErrors[forwardID] = reason.isEmpty ? nil : reason
            if !reason.isEmpty { log.append(id, .error, "Forward \(forwardName(id, forwardID)): \(reason)") }
        }
    }

    private func noteDrop(_ id: UUID, reason: String) {
        log.append(id, .error, "Dropped: \(reason)")
        if let connection = store.connection(id) { notifier.dropped(connection, reason: reason) }
    }

    private func forwardName(_ id: UUID, _ forwardID: UUID) -> String {
        store.connection(id)?.forwards.first { $0.id == forwardID }?.displayName ?? "forward"
    }

    private func scheduleReconnect(_ id: UUID) {
        guard wanted.contains(id), store.connection(id)?.autoReconnect == true else { return }
        let delay = backoff(&attempts[id, default: 0])
        log.append(id, .info, "Reconnecting in \(Int(delay))s")
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await connect(id)
        }
    }

    private func scheduleForwardRetry(_ id: UUID) {
        guard wanted.contains(id), store.connection(id)?.autoReconnect == true else { return }
        let delay = backoff(&forwardAttempts[id, default: 0])
        log.append(id, .info, "Retrying forwards in \(Int(delay))s")
        forwardRetryTasks[id]?.cancel()
        forwardRetryTasks[id] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, statuses[id] == .connected else { return }
            await applyForwards(id)
        }
    }

    private func backoff(_ attempt: inout Int) -> Double {
        defer { attempt += 1 }
        return min(3.0 * pow(2.0, Double(attempt)), 60.0)
    }

    private func cancelRetries(_ id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        forwardRetryTasks[id]?.cancel()
        forwardRetryTasks[id] = nil
    }

    private func scheduleRecheck(after seconds: Double) {
        recheckTask?.cancel()
        recheckTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await recheckAll()
        }
    }

    private func recheckAll() async {
        for id in wanted {
            switch statuses[id] {
            case .connected:
                guard let session = sessions[id] else { continue }
                if await probe(id, session) == nil, sessions[id] === session {
                    noteDrop(id, reason: "Stopped responding")
                    attempts[id] = 0
                    await connectFresh(id)
                } else if forwardErrors.keys.contains(where: { forwardID in store.connection(id)?.forwards.contains { $0.id == forwardID } ?? false }) {
                    forwardAttempts[id] = 0
                    await applyForwards(id)
                }
            case .failed, .disconnected, .none:
                cancelRetries(id)
                attempts[id] = 0
                await connect(id)
            case .connecting:
                continue
            }
        }
    }

    private func connectFresh(_ id: UUID) async {
        if let running = connectTasks[id] {
            await running.value
            connectTasks[id] = nil
        }
        activeForwards[id] = nil
        clearForwardErrors(id)
        stopLatencyProbes(id)
        if let session = sessions[id] {
            sessions[id] = nil
            await session.disconnect()
        }
        await connect(id)
    }

    private func probe(_ id: UUID, _ session: any ForwardSession) async -> TimeInterval? {
        let roundTrip = await session.probe()
        guard sessions[id] === session else { return nil }
        latency[id] = roundTrip
        if roundTrip == nil { log.append(id, .info, "Probe failed") }
        return roundTrip
    }

    // Kubernetes and AWS probes are API calls, so only SSH links are polled continuously.
    private func startLatencyProbes(_ id: UUID, _ session: any ForwardSession) {
        latencyTasks[id]?.cancel()
        guard store.connection(id)?.kind == .ssh else { return }
        latencyTasks[id] = Task {
            while !Task.isCancelled, sessions[id] === session {
                if await probe(id, session) == nil, !Task.isCancelled, sessions[id] === session {
                    noteDrop(id, reason: "Stopped responding")
                    attempts[id] = 0
                    await connectFresh(id)
                    return
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopLatencyProbes(_ id: UUID) {
        latencyTasks[id]?.cancel()
        latencyTasks[id] = nil
        latency[id] = nil
    }

    private func reconcile(_ connections: [Connection]) async {
        for (id, session) in sessions where statuses[id] == .connected {
            guard let connection = connections.first(where: { $0.id == id }) else {
                await setWanted(id, false)
                continue
            }
            if connection.identity != session.identity {
                await connectFresh(id)
            } else {
                await applyForwards(id)
            }
        }
    }

    private func applyForwards(_ id: UUID) async {
        guard let session = sessions[id], let connection = store.connection(id) else { return }
        let before = activeForwards[id] ?? []
        let errors = await session.apply(desired: connection.forwards)
        guard sessions[id] === session else { return }
        let after = await session.activeForwardIDs
        activeForwards[id] = after
        for forward in connection.forwards {
            forwardErrors[forward.id] = errors[forward.id]
            if let reason = errors[forward.id] {
                log.append(id, .error, "Forward \(forward.displayName) failed: \(reason)")
            } else if after.contains(forward.id) && !before.contains(forward.id) {
                log.append(id, .info, "Forward \(forward.displayName) applied")
            } else if before.contains(forward.id) && !after.contains(forward.id) {
                log.append(id, .info, "Forward \(forward.displayName) removed")
            }
        }
        if errors.isEmpty {
            forwardAttempts[id] = 0
        } else {
            scheduleForwardRetry(id)
        }
    }

    private func clearForwardErrors(_ id: UUID) {
        for forward in store.connection(id)?.forwards ?? [] {
            forwardErrors[forward.id] = nil
        }
    }
}
