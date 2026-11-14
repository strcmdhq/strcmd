import Foundation

enum ClaudeRole: Hashable, Sendable {
    case session, helper
}

struct DevServer: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    var startTime: Date?
    var ports: [UInt16] = []
    var id: Int32 { pid }
}

struct WildcardListener: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    let socket: ListeningSocket
    var sessionPID: Int32?
    var id: String { "\(pid)-\(socket.address)-\(socket.port)" }
}

struct ClaudeSession: Identifiable, Hashable, Sendable {
    let pid: Int32
    var role: ClaudeRole = .session
    var cwd = ""
    var startTime: Date?
    var memoryBytes: UInt64 = 0
    var cpuPercent: Double = 0
    var treeMemoryBytes: UInt64 = 0
    var treeCPUPercent: Double = 0
    var descendantCount = 0
    var devServers: [DevServer] = []
    var lastActivity: Date?
    var id: Int32 { pid }

    var folderName: String { cwd.isEmpty ? "unknown" : URL(fileURLWithPath: cwd).lastPathComponent }

    func age(at now: Date) -> TimeInterval { startTime.map { now.timeIntervalSince($0) } ?? 0 }

    func isActive(at now: Date) -> Bool {
        lastActivity.map { now.timeIntervalSince($0) < ClaudeSessionRules.activeWindow } ?? false
    }

    func idle(at now: Date) -> TimeInterval {
        now.timeIntervalSince(lastActivity ?? startTime ?? now)
    }
}

struct SwapUsage: Hashable, Sendable {
    let total: UInt64
    let used: UInt64

    init(total: UInt64, used: UInt64) {
        self.total = total
        self.used = used
    }

    init(_ usage: xsw_usage) {
        self.init(total: usage.xsu_total, used: usage.xsu_used)
    }

    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    var isHigh: Bool { fraction > ClaudeSessionRules.swapWarning }
}

struct ClaudeSnapshot: Hashable, Sendable {
    var sessions: [ClaudeSession] = []
    var helpers: [ClaudeSession] = []
    var totalMemoryBytes: UInt64 = 0
    var wildcardListeners: [WildcardListener] = []
    var swap: SwapUsage?

    static let empty = ClaudeSnapshot()
}

enum ClaudeSessionRules {
    static let activeWindow: TimeInterval = 5 * 60
    static let swapWarning = 0.8
    static let helperCommands: Set = ["bg-pty-host", "bg-spare", "--bg-pty-host", "--bg-spare", "daemon"]
    static let nonSessionCommands: Set = ["mcp", "config", "update", "doctor", "install", "setup-token", "migrate-installer"]
    static let devServerNames: Set = ["node", "vite", "tsx", "python", "python3", "docker", "docker-compose", "bun", "deno", "npm", "pnpm", "yarn", "next-server"]

    static func classify(arguments: [String], executablePath: String) -> ClaudeRole? {
        let arguments = titleTokens(arguments)
        guard let first = arguments.first, URL(fileURLWithPath: first).lastPathComponent == "claude" else { return nil }
        guard arguments.count > 1 else { return executablePath.contains(".app/") ? nil : .session }
        let command = arguments[1]
        if helperCommands.contains(command) { return .helper }
        if executablePath.contains(".app/") { return nil }
        if command.hasPrefix("-") { return .session }
        return nonSessionCommands.contains(command) ? nil : .session
    }

    // Helpers overwrite argv with a space-joined title, e.g. "claude bg-spare --bg-spare <sock>".
    static func titleTokens(_ arguments: [String]) -> [String] {
        guard let title = arguments.first, title.hasPrefix("claude ") else { return arguments }
        return title.split(separator: " ").map(String.init)
    }

    static func devServerName(arguments: [String], executablePath: String) -> String? {
        let candidates = [arguments.first, executablePath].compactMap { $0 }.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        return candidates.first { devServerNames.contains(normalized($0)) }
    }

    private static func normalized(_ name: String) -> String {
        name.hasPrefix("python3") ? "python3" : name
    }

    static func projectsFolderName(for cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    static func isStale(_ session: ClaudeSession, days: Int, now: Date) -> Bool {
        session.role == .session && !session.isActive(at: now) && session.idle(at: now) > TimeInterval(days) * 86_400
    }
}

enum ProcArgs {
    static func parse(_ buffer: [UInt8]) -> (path: String, arguments: [String])? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let argc = buffer.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var index = countSize
        guard let path = string(in: buffer, from: &index) else { return nil }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), let argument = string(in: buffer, from: &index) {
            arguments.append(argument)
        }
        return (path, arguments)
    }

    private static func string(in buffer: [UInt8], from index: inout Int) -> String? {
        guard index < buffer.count, let end = buffer[index...].firstIndex(of: 0) else { return nil }
        defer { index = end + 1 }
        return String(decoding: buffer[index..<end], as: UTF8.self)
    }
}

enum ProcessTree {
    static func children(_ parents: [Int32: Int32]) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent {
            children[parent, default: []].append(pid)
        }
        return children
    }

    static func descendants(of root: Int32, children: [Int32: [Int32]], stoppingAt boundaries: Set<Int32> = []) -> [Int32] {
        var found: [Int32] = []
        var seen: Set<Int32> = [root]
        var stack = children[root] ?? []
        while let pid = stack.popLast() {
            guard !boundaries.contains(pid), seen.insert(pid).inserted else { continue }
            found.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return found
    }

    static func nearestAncestor(of pid: Int32, in candidates: Set<Int32>, parents: [Int32: Int32]) -> Int32? {
        var current = pid
        var seen: Set<Int32> = []
        while seen.insert(current).inserted {
            if candidates.contains(current) { return current }
            guard let parent = parents[current], parent > 0 else { return nil }
            current = parent
        }
        return nil
    }
}
