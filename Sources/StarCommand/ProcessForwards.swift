import Foundation

struct ForwardLaunch: Equatable {
    let forward: PortForward
    let tool: URL
    let arguments: [String]
}

// kubectl and aws ssm have no multiplexing: every forward is its own long-running process.
actor ProcessForwards {
    typealias ExitHandler = @Sendable (UUID, String) -> Void

    private let registry: ProcessRegistry
    private let log: SessionLogHandler
    private var processes: [UUID: Process] = [:]
    private var commands: [UUID: [String]] = [:]
    private var onExit: ExitHandler?

    init(registry: ProcessRegistry, log: @escaping SessionLogHandler) {
        self.registry = registry
        self.log = log
    }

    var activeIDs: Set<UUID> { Set(processes.keys) }

    func setExitHandler(_ handler: @escaping ExitHandler) {
        onExit = handler
    }

    func apply(_ wanted: [UUID: ForwardLaunch]) async -> [UUID: String] {
        for (id, process) in processes where wanted[id]?.arguments != commands[id] {
            stop(id, process)
        }
        var errors: [UUID: String] = [:]
        for (id, launch) in wanted where processes[id] == nil {
            do {
                try await start(launch)
            } catch {
                errors[id] = error.localizedDescription
            }
        }
        return errors
    }

    func stopAll() {
        for (id, process) in processes { stop(id, process) }
    }

    private func start(_ launch: ForwardLaunch) async throws {
        let forward = launch.forward
        if Tools.isListening(port: forward.localPort) {
            throw ToolError(message: "\(forward.localPort): Address already in use")
        }
        let name = launch.tool.lastPathComponent
        let process = Tools.makeProcess(launch.tool, launch.arguments)
        let output = OutputBuffer { [log, label = forward.displayName] line in
            log(.info, "\(name)[\(label)]: \(line)")
        }
        Tools.captureStderr(of: process, into: output)
        let id = forward.id
        process.terminationHandler = { [registry] finished in
            registry.remove(finished)
            Task { await self.exited(id, finished, output.text) }
        }
        log(.info, "$ " + Tools.commandLine(launch.tool, launch.arguments))
        do {
            try process.run()
        } catch {
            throw ToolError(message: error.localizedDescription)
        }
        registry.add(process)
        processes[id] = process
        commands[id] = launch.arguments

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !process.isRunning {
                processes[id] = nil
                commands[id] = nil
                throw ToolError(message: Tools.lastLine(output.text) ?? "\(name) exited with status \(process.terminationStatus)")
            }
            if Tools.isListening(port: forward.localPort) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        stop(id, process)
        throw ToolError(message: "Timed out waiting for port \(forward.localPort)")
    }

    private func stop(_ id: UUID, _ process: Process) {
        processes[id] = nil
        commands[id] = nil
        process.terminationHandler = { [registry] finished in registry.remove(finished) }
        if process.isRunning { process.terminate() }
    }

    private func exited(_ id: UUID, _ process: Process, _ output: String) {
        guard processes[id] === process else { return }
        processes[id] = nil
        commands[id] = nil
        onExit?(id, Tools.lastLine(output) ?? "Forward exited with status \(process.terminationStatus)")
    }
}
