import Darwin
import Foundation

struct ProcessSample: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    var path = ""
    var parentPID: Int32 = 0
    var parentName = ""
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var diskBytesPerSecond: UInt64 = 0
    var threadCount = 0
    var ports: [UInt16] = []
    var paused = false
    var sockets: [ListeningSocket] = []
    var startTime: Date?
    var arguments: [String] = []
    var id: Int32 { pid }
    var portsText: String { ProcessMonitor.portList(ports) }
}

struct ListeningSocket: Hashable, Sendable {
    let port: UInt16
    let address: String

    var isWildcard: Bool { address == "0.0.0.0" || address == "::" || address == "*" }
}

struct PortListener: Hashable, Sendable {
    let pid: Int32
    let name: String
}

struct SystemSample: Sendable {
    let cpuPercent: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let loadAverages: [Double]
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var system: SystemSample?
    @Published private(set) var claude: ClaudeSnapshot
    private var observers = 0
    private var loop: Task<Void, Never>?
    private lazy var ancestors = ProcInfo.ancestors(of: getpid())

    init(claude: ClaudeSnapshot = .empty) {
        self.claude = claude
    }

    var topProcesses: [ProcessSample] { Array(processes.prefix(3)) }

    func start() {
        observers += 1
        guard observers == 1, loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            var sampler = ProcessSampler()
            var sessions = ClaudeSessionSampler()
            _ = sampler.sample()
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                guard let self else { return }
                let (system, processes) = sampler.sample()
                let claude = sessions.update(processes)
                await self.publish(system, processes, claude)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func publish(_ system: SystemSample, _ processes: [ProcessSample], _ claude: ClaudeSnapshot) {
        self.system = system
        self.processes = processes
        self.claude = claude
    }

    func stop() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    func lookupListener(port: UInt16) async -> PortListener? {
        await Task.detached(priority: .userInitiated) { ProcessSampler.scanListeners()[port] }.value
    }

    func freePort(_ port: UInt16) async -> String {
        guard let listener = await lookupListener(port: port) else { return "Nothing of yours is listening on \(port)" }
        if let error = terminate(pid: listener.pid, force: false) { return "\(listener.name) (\(listener.pid)): \(error)" }
        return "Quit \(listener.name) (\(listener.pid)) on \(port)"
    }

    func terminate(pid: Int32, force: Bool) -> String? {
        send(pid, force ? SIGKILL : SIGTERM)
    }

    func pause(pid: Int32) -> String? {
        send(pid, SIGSTOP)
    }

    func resume(pid: Int32) -> String? {
        send(pid, SIGCONT)
    }

    func setPriority(pid: Int32, nice: Int32) -> String? {
        guard pid != getpid() else { return "That is Star Command itself" }
        guard setpriority(PRIO_PROCESS, id_t(pid), nice) != 0 else { return nil }
        return errno == EACCES || errno == EPERM ? "Can't raise priority without a privileged helper" : String(cString: strerror(errno))
    }

    private func send(_ pid: Int32, _ sig: Int32) -> String? {
        if let refusal = Self.refusal(pid: pid, identity: ProcInfo.identity(pid: pid), ownPID: getpid(), ownUID: getuid(), ancestors: ancestors) {
            return refusal
        }
        return kill(pid, sig) == 0 ? nil : String(cString: strerror(errno))
    }

    nonisolated static func refusal(pid: Int32, identity: ProcInfo.Identity?, ownPID: Int32, ownUID: uid_t, ancestors: Set<Int32>) -> String? {
        guard pid > 1 else { return "Refusing to signal pid \(pid)" }
        guard pid != ownPID else { return "That is Star Command itself" }
        guard !ancestors.contains(pid) else { return "That process launched Star Command" }
        guard let identity else { return "No longer running" }
        guard identity.uid == ownUID else { return "Not your process" }
        return nil
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    nonisolated static func rate(_ bytesPerSecond: UInt64) -> String {
        bytesPerSecond == 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    nonisolated static func portList(_ ports: [UInt16]) -> String {
        Set(ports).sorted().map(String.init).joined(separator: ", ")
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
