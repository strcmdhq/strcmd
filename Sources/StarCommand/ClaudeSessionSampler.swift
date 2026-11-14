import Foundation

struct ClaudeSessionSampler {
    static let transcriptInterval: TimeInterval = 30

    private struct Key: Hashable {
        let pid: Int32
        let startTime: Date?
    }

    private var directories: [Key: String] = [:]
    private var transcripts: [String: (checked: Date, modified: Date?)] = [:]
    private let projectsRoot: URL
    private let currentDirectory: (Int32) -> String?
    private let swapUsage: () -> SwapUsage?

    init(
        projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        currentDirectory: @escaping (Int32) -> String? = ProcInfo.currentDirectory,
        swapUsage: @escaping () -> SwapUsage? = ProcInfo.swapUsage
    ) {
        self.projectsRoot = projectsRoot
        self.currentDirectory = currentDirectory
        self.swapUsage = swapUsage
    }

    mutating func update(_ processes: [ProcessSample], now: Date = Date()) -> ClaudeSnapshot {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let roles = byPID.compactMapValues { ClaudeSessionRules.classify(arguments: $0.arguments, executablePath: $0.path) }
        let children = ProcessTree.children(byPID.mapValues(\.parentPID))
        let roots = Set(roles.keys)
        var seen: Set<Key> = []
        var sessions: [ClaudeSession] = []
        var helpers: [ClaudeSession] = []
        for (pid, role) in roles {
            guard let process = byPID[pid] else { continue }
            let key = Key(pid: pid, startTime: process.startTime)
            seen.insert(key)
            let cwd = directories[key] ?? currentDirectory(pid) ?? ""
            directories[key] = cwd
            var session = Self.summarize(process, role: role, cwd: cwd, tree: ProcessTree.descendants(of: pid, children: children, stoppingAt: roots).compactMap { byPID[$0] })
            if role == .session {
                session.lastActivity = lastActivity(cwd: cwd, now: now)
                sessions.append(session)
            } else {
                helpers.append(session)
            }
        }
        directories = directories.filter { seen.contains($0.key) }
        let liveFolders = Set(sessions.map(\.cwd))
        transcripts = transcripts.filter { liveFolders.contains($0.key) }
        let sessionPIDs = Set(sessions.map(\.pid))
        return ClaudeSnapshot(
            sessions: sessions.sorted { $0.treeMemoryBytes > $1.treeMemoryBytes },
            helpers: helpers.sorted { $0.pid < $1.pid },
            totalMemoryBytes: sessions.reduce(0) { $0 + $1.treeMemoryBytes },
            wildcardListeners: Self.wildcardListeners(processes, sessions: sessionPIDs, parents: byPID.mapValues(\.parentPID)),
            swap: swapUsage()
        )
    }

    static func summarize(_ process: ProcessSample, role: ClaudeRole, cwd: String, tree: [ProcessSample]) -> ClaudeSession {
        let listening = listeningLineage(tree, root: process.pid)
        let devServers = tree.filter { listening.contains($0.pid) }.compactMap { child in
            ClaudeSessionRules.devServerName(arguments: child.arguments, executablePath: child.path).map {
                DevServer(pid: child.pid, name: $0, startTime: child.startTime, ports: child.ports)
            }
        }
        return ClaudeSession(
            pid: process.pid,
            role: role,
            cwd: cwd,
            startTime: process.startTime,
            memoryBytes: process.memoryBytes,
            cpuPercent: process.cpuPercent,
            treeMemoryBytes: tree.reduce(process.memoryBytes) { $0 + $1.memoryBytes },
            treeCPUPercent: tree.reduce(process.cpuPercent) { $0 + $1.cpuPercent },
            descendantCount: tree.count,
            devServers: devServers.sorted { $0.pid < $1.pid }
        )
    }

    // MCP servers are node/python too; only processes that listen, or launched one that does, count as dev servers.
    static func listeningLineage(_ tree: [ProcessSample], root: Int32) -> Set<Int32> {
        let parents = Dictionary(tree.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        var lineage: Set<Int32> = []
        for listener in tree where !listener.ports.isEmpty {
            var current: Int32? = listener.pid
            while let pid = current, pid != root, lineage.insert(pid).inserted {
                current = parents[pid]
            }
        }
        return lineage
    }

    static func wildcardListeners(_ processes: [ProcessSample], sessions: Set<Int32>, parents: [Int32: Int32]) -> [WildcardListener] {
        processes.flatMap { process in
            process.sockets.filter(\.isWildcard).map {
                WildcardListener(pid: process.pid, name: process.name, socket: $0, sessionPID: ProcessTree.nearestAncestor(of: process.pid, in: sessions, parents: parents))
            }
        }
        .sorted { ($0.socket.port, $0.pid) < ($1.socket.port, $1.pid) }
    }

    static func newestTranscript(in folder: URL) -> Date? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    func transcriptFolder(cwd: String) -> URL? {
        guard !cwd.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return [cwd, resolved].lazy
            .map { projectsRoot.appendingPathComponent(ClaudeSessionRules.projectsFolderName(for: $0)) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private mutating func lastActivity(cwd: String, now: Date) -> Date? {
        if let cached = transcripts[cwd], now.timeIntervalSince(cached.checked) < Self.transcriptInterval {
            return cached.modified
        }
        let modified = transcriptFolder(cwd: cwd).flatMap(Self.newestTranscript)
        transcripts[cwd] = (now, modified)
        return modified
    }
}
