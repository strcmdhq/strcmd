import Foundation

actor SSHSession: ForwardSession {
    nonisolated let identity: String
    private let destination: String
    private let controlPath: String
    private let registry: ProcessRegistry
    private let log: SessionLogHandler
    private var master: Process?
    private let masterLog: OutputBuffer
    private var active: [UUID: [String]] = [:]

    init(connection: Connection, registry: ProcessRegistry, log: @escaping SessionLogHandler) {
        identity = connection.identity
        destination = connection.destination
        self.registry = registry
        self.log = log
        masterLog = OutputBuffer { line in log(.info, "ssh: \(line)") }
        controlPath = "/tmp/strcmd-\(connection.id.uuidString.prefix(8)).sock"
    }

    var activeForwardIDs: Set<UUID> { Set(active.keys) }

    private var ssh: URL { URL(fileURLWithPath: "/usr/bin/ssh") }

    // -F /dev/null keeps ~/.ssh/config forwards out of -O forward/cancel; ClearAllForwardings would also drop the -L.
    private var controlArgs: [String] {
        ["-S", controlPath, "-F", "/dev/null", "-o", "BatchMode=yes"]
    }

    func connect(onDrop: @escaping DropHandler) async throws {
        if await isAlive() {
            _ = await Tools.run(ssh, controlArgs + ["-O", "exit", destination])
        }
        try? FileManager.default.removeItem(atPath: controlPath)

        let process = Tools.makeProcess(ssh, [
            "-M", "-N", "-S", controlPath,
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            destination,
        ])
        let output = masterLog
        Tools.captureStderr(of: process, into: output)
        let registry = registry
        process.terminationHandler = { finished in
            registry.remove(finished)
            onDrop(.connection, Tools.lastLine(output.text) ?? "Connection dropped (ssh exited \(finished.terminationStatus))")
        }

        log(.info, "$ " + Tools.commandLine(ssh, process.arguments!))
        do {
            try process.run()
        } catch {
            throw ToolError(message: error.localizedDescription)
        }
        registry.add(process)
        master = process

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !process.isRunning {
                master = nil
                throw ToolError(message: Tools.lastLine(output.text) ?? "ssh exited with status \(process.terminationStatus)")
            }
            if await isAlive() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        master = nil
        throw ToolError(message: "Timed out waiting for the connection")
    }

    func isAlive() async -> Bool {
        await Tools.run(ssh, controlArgs + ["-O", "check", destination]).status == 0
    }

    // A real round trip through the multiplexed connection, unlike -O check which only talks to the local master.
    func probe() async -> TimeInterval? {
        await timedProbe { await Tools.run(ssh, controlArgs + [destination, "true"], timeout: 10).status == 0 }
    }

    func apply(desired: [PortForward]) async -> [UUID: String] {
        var errors: [UUID: String] = [:]
        let wanted = Dictionary(uniqueKeysWithValues: desired.filter(\.enabled).map { ($0.id, $0.sshArguments) })

        for (id, args) in active where wanted[id] != args {
            _ = await Tools.run(ssh, logged(controlArgs + ["-O", "cancel"] + args + [destination]))
            active[id] = nil
        }
        for (id, args) in wanted where active[id] == nil {
            let logBefore = masterLog.text.count
            let result = await Tools.run(ssh, logged(controlArgs + ["-O", "forward"] + args + [destination]))
            if result.status == 0 {
                active[id] = args
            } else {
                let masterOutput = String(masterLog.text.dropFirst(logBefore))
                errors[id] = Self.cleanError(Tools.firstLine(masterOutput) ?? Tools.lastLine(result.stderr) ?? "Forward failed")
            }
        }
        return errors
    }

    func disconnect() async {
        guard let process = master else { return }
        master = nil
        active = [:]
        process.terminationHandler = { [registry] finished in registry.remove(finished) }
        _ = await Tools.run(ssh, controlArgs + ["-O", "exit", destination])
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
    }

    private func logged(_ arguments: [String]) -> [String] {
        log(.info, "$ " + Tools.commandLine(ssh, arguments))
        return arguments
    }

    private static func cleanError(_ line: String) -> String {
        var text = line
        for prefix in ["Warning: ", "mux_client_forward: ", "mux_client_request_session: ", "bind [127.0.0.1]:"] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        }
        return text
    }
}
