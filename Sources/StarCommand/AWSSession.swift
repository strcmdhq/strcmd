import Foundation

actor AWSSession: ForwardSession {
    nonisolated let identity: String
    private let connection: Connection
    private let processes: ProcessForwards
    private let log: SessionLogHandler
    private var onDrop: DropHandler?
    private var gateways: [UUID: RunningGateway] = [:]
    private var jumpHost: String?
    private var jumpHostStale = false
    private var endpoints: [String: String] = [:]

    private struct RunningGateway {
        let gateway: AirflowGateway
        let token: UUID
        let port: Int
        let environment: String
    }

    init(connection: Connection, registry: ProcessRegistry, log: @escaping SessionLogHandler) {
        identity = connection.identity
        self.connection = connection
        self.log = log
        processes = ProcessForwards(registry: registry, log: log)
    }

    var activeForwardIDs: Set<UUID> {
        get async { await processes.activeIDs.union(gateways.keys) }
    }

    func connect(onDrop: @escaping DropHandler) async throws {
        self.onDrop = onDrop
        await processes.setExitHandler { [weak self] id, reason in
            Task { await self?.processExited(id, reason) }
        }
        let aws = try Tools.require("aws")
        let args = connection.awsBaseArguments + ["sts", "get-caller-identity"]
        log(.info, "$ " + Tools.commandLine(aws, args))
        var result = await Tools.run(aws, args, timeout: 30)
        if result.status != 0, AWSCLI.isSSOExpired(result.stderr), await signIn() {
            result = await Tools.run(aws, args, timeout: 30)
        }
        if result.status != 0 {
            throw ToolError(message: AWSCLI.explain(result.stderr, profile: connection.awsProfile, fallback: "aws sts get-caller-identity failed"))
        }
    }

    private func signIn() async -> Bool {
        guard connection.autoSSOLogin else { return false }
        return await SSOLogin.shared.signIn(profile: connection.awsProfile, log: log)
    }

    func probe() async -> TimeInterval? {
        guard let aws = Tools.find("aws") else { return nil }
        return await timedProbe { await Tools.run(aws, connection.awsBaseArguments + ["sts", "get-caller-identity"], timeout: 30).status == 0 }
    }

    func apply(desired: [PortForward]) async -> [UUID: String] {
        let errors = await applyOnce(desired)
        guard errors.values.contains(where: AWSCLI.isSSOExpired), await signIn() else { return errors }
        return await applyOnce(desired)
    }

    private func applyOnce(_ desired: [PortForward]) async -> [UUID: String] {
        let enabled = desired.filter(\.enabled)
        var errors = await applyGateways(enabled.filter { $0.awsService == .mwaa })
        var launches: [UUID: ForwardLaunch] = [:]
        for forward in enabled where forward.awsService.needsSSM {
            do {
                launches[forward.id] = try await launch(forward)
            } catch {
                errors[forward.id] = error.localizedDescription
            }
        }
        let failed = await processes.apply(launches)
        if !failed.isEmpty { jumpHostStale = true }
        return errors.merging(failed) { first, _ in first }
    }

    func disconnect() async {
        for (id, running) in gateways { stopGateway(id, running) }
        await processes.stopAll()
    }

    private func processExited(_ id: UUID, _ reason: String) {
        jumpHostStale = true
        onDrop?(.forward(id), reason)
    }

    private func launch(_ forward: PortForward) async throws -> ForwardLaunch {
        _ = try Tools.require("session-manager-plugin", hint: "Install it with: brew install --cask session-manager-plugin")
        let aws = try Tools.require("aws")
        let target = try await resolveJumpHost()
        let host: String
        switch forward.awsService {
        case .rds:
            host = try await rdsAddress(forward.awsResource)
        case .msk where forward.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty:
            throw ToolError(message: "Pick a broker for this Kafka forward")
        default:
            host = forward.remoteHost
        }
        let args = SSMCommand.arguments(base: connection.awsBaseArguments, target: target, host: host, remotePort: forward.remotePort, localPort: forward.localPort)
        return ForwardLaunch(forward: forward, tool: aws, arguments: args)
    }

    // Nodes come and go with autoscaling, so a pattern is resolved to a live instance per session and after drops.
    private func resolveJumpHost() async throws -> String {
        let setting = JumpHost(setting: connection.awsTarget)
        if case .instance(let id) = setting { return id }
        if let jumpHost, !jumpHostStale { return jumpHost }
        let candidates = try await AWSDiscovery.onlineInstances(try Tools.require("aws"), base: connection.awsBaseArguments, profile: connection.awsProfile, nameFilter: setting.nameFilter)
        guard let chosen = JumpHost.choose(candidates, current: jumpHost) else {
            let scope = setting.nameFilter.map { "matching Name \($0)" } ?? "in \(connection.awsProfile) \(connection.awsRegion)"
            throw ToolError(message: "No SSM-online instance \(scope)")
        }
        if chosen.id != jumpHost {
            log(.info, "Jump host: \(chosen.id)\(chosen.name.isEmpty ? "" : " (\(chosen.name))")")
        }
        jumpHost = chosen.id
        jumpHostStale = false
        return chosen.id
    }

    private func rdsAddress(_ identifier: String) async throws -> String {
        let identifier = identifier.trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { throw ToolError(message: "Pick a database for this RDS forward") }
        if let address = endpoints[identifier] { return address }
        let aws = try Tools.require("aws")
        let result = await Tools.capture(aws, connection.awsBaseArguments + ["rds", "describe-db-instances", "--db-instance-identifier", identifier, "--output", "json"], timeout: 30)
        guard result.status == 0, let database = AWSDiscovery.parseDatabases(result.stdout).first else {
            throw ToolError(message: result.status == 0 ? "\(identifier) has no endpoint yet" : AWSCLI.explain(result.stderr, profile: connection.awsProfile))
        }
        log(.info, "RDS \(identifier): \(database.address):\(database.port)")
        endpoints[identifier] = database.address
        return database.address
    }

    private func applyGateways(_ wanted: [PortForward]) async -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0) })
        for (id, running) in gateways where byID[id].map({ $0.localPort != running.port || $0.awsResource != running.environment }) ?? true {
            stopGateway(id, running)
        }
        var errors: [UUID: String] = [:]
        for forward in wanted where gateways[forward.id] == nil {
            if let reason = await startGateway(forward) { errors[forward.id] = reason }
        }
        return errors
    }

    private func startGateway(_ forward: PortForward) async -> String? {
        let environment = forward.awsResource.trimmingCharacters(in: .whitespaces)
        guard !environment.isEmpty else { return "Pick an Airflow environment" }
        guard let port = UInt16(exactly: forward.localPort), port > 0 else { return "Invalid local port \(forward.localPort)" }
        if Tools.isListening(port: forward.localPort) { return "\(forward.localPort): Address already in use" }

        let id = forward.id
        let token = UUID()
        let first = FirstState()
        let base = connection.awsBaseArguments
        let profile = connection.awsProfile
        let gateway = AirflowGateway(port: port, mint: { [weak self] in
            let result = await MWAA.loginURL(base: base, profile: profile, environment: environment)
            await self?.minted(id, token, result)
            return result
        }, onState: { [weak self] state in
            guard !first.deliver(state), case .failed(let reason) = state else { return }
            Task { await self?.gatewayFailed(id, token, reason) }
        })
        let state = await withCheckedContinuation { continuation in
            first.wait(continuation)
            gateway.start()
            Task {
                try? await Task.sleep(for: .seconds(10))
                first.deliver(.failed("Timed out opening port \(port)"))
            }
        }
        guard state == .listening else {
            gateway.stop()
            if case .failed(let reason) = state { return reason }
            return "Couldn't listen on port \(port)"
        }
        gateways[id] = RunningGateway(gateway: gateway, token: token, port: forward.localPort, environment: environment)
        log(.info, "Airflow \(environment) sign-in gateway on localhost:\(port)")
        return nil
    }

    private func stopGateway(_ id: UUID, _ running: RunningGateway) {
        gateways[id] = nil
        running.gateway.stop()
    }

    private func gatewayFailed(_ id: UUID, _ token: UUID, _ reason: String) {
        guard let running = gateways[id], running.token == token else { return }
        stopGateway(id, running)
        onDrop?(.forward(id), reason)
    }

    private func minted(_ id: UUID, _ token: UUID, _ result: Result<URL, ToolError>) {
        guard gateways[id]?.token == token else { return }
        switch result {
        case .success: onDrop?(.forwardNotice(id), "")
        case .failure(let error): onDrop?(.forwardNotice(id), error.message)
        }
    }
}

private final class FirstState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AirflowGateway.State, Never>?
    private var delivered = false

    func wait(_ continuation: CheckedContinuation<AirflowGateway.State, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    @discardableResult
    func deliver(_ state: AirflowGateway.State) -> Bool {
        lock.lock()
        guard !delivered, let continuation else {
            lock.unlock()
            return false
        }
        delivered = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: state)
        return true
    }
}
