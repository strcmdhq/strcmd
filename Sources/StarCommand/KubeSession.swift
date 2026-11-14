import Foundation

actor KubeSession: ForwardSession {
    nonisolated let identity: String
    private let connection: Connection
    private let processes: ProcessForwards
    private let log: SessionLogHandler

    init(connection: Connection, registry: ProcessRegistry, log: @escaping SessionLogHandler) {
        identity = connection.identity
        self.connection = connection
        self.log = log
        processes = ProcessForwards(registry: registry, log: log)
    }

    var activeForwardIDs: Set<UUID> {
        get async { await processes.activeIDs }
    }

    func connect(onDrop: @escaping DropHandler) async throws {
        await processes.setExitHandler { id, reason in onDrop(.forward(id), reason) }
        let (tool, args) = try validationCommand()
        log(.info, "$ " + Tools.commandLine(tool, args))
        let result = await Tools.run(tool, args, timeout: 30)
        if result.status != 0 {
            throw ToolError(message: Tools.lastLine(result.stderr) ?? "kubectl exited with status \(result.status)")
        }
    }

    func probe() async -> TimeInterval? {
        guard let (tool, args) = try? validationCommand() else { return nil }
        return await timedProbe { await Tools.run(tool, args, timeout: 30).status == 0 }
    }

    func apply(desired: [PortForward]) async -> [UUID: String] {
        guard let kubectl = try? Tools.require("kubectl") else {
            return Dictionary(uniqueKeysWithValues: desired.filter(\.enabled).map { ($0.id, "kubectl not found on PATH") })
        }
        let wanted = desired.filter(\.enabled).map { forward in
            (forward.id, ForwardLaunch(forward: forward, tool: kubectl, arguments: [
                "--context", connection.kubeContext,
                "--namespace", connection.kubeNamespace,
                "port-forward", "--address", "127.0.0.1",
                forward.remoteHost, "\(forward.localPort):\(forward.remotePort)",
            ]))
        }
        return await processes.apply(Dictionary(uniqueKeysWithValues: wanted))
    }

    func disconnect() async {
        await processes.stopAll()
    }

    private func validationCommand() throws -> (URL, [String]) {
        (try Tools.require("kubectl"), ["--context", connection.kubeContext, "--request-timeout=15s", "get", "--raw", "/version"])
    }
}
