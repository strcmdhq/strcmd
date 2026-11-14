import Foundation

struct ClaudeInsights {
    struct Crowd: Hashable {
        let folder: String
        let count: Int
        var text: String { "\(count) sessions in \(folder)" }
    }

    let snapshot: ClaudeSnapshot
    let staleDays: Int
    let now: Date

    var sessionCount: Int { snapshot.sessions.count }
    var stale: [ClaudeSession] { snapshot.sessions.filter { ClaudeSessionRules.isStale($0, days: staleDays, now: now) } }
    var olderCount: Int { snapshot.sessions.filter { $0.age(at: now) > TimeInterval(staleDays) * 86_400 }.count }
    var activeCount: Int { snapshot.sessions.filter { $0.isActive(at: now) }.count }
    var swapHigh: Bool { snapshot.swap?.isHigh ?? false }
    var warning: Bool { !stale.isEmpty || swapHigh }

    var crowds: [Crowd] {
        Dictionary(grouping: snapshot.sessions.filter { !$0.cwd.isEmpty }, by: \.cwd)
            .filter { $0.value.count > 1 }
            .map { Crowd(folder: URL(fileURLWithPath: $0.key).lastPathComponent, count: $0.value.count) }
            .sorted { ($1.count, $0.folder) < ($0.count, $1.folder) }
    }

    var menuText: String {
        "Claude: \(ClaudeFormat.count(sessionCount, "session")) · \(ClaudeFormat.memory(snapshot.totalMemoryBytes))"
    }

    var swapText: String? {
        snapshot.swap.map { "Swap \(ClaudeFormat.memory($0.used)) of \(ClaudeFormat.memory($0.total)) (\(Int(($0.fraction * 100).rounded()))%)" }
    }
}

enum ClaudeFormat {
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        switch minutes {
        case ..<60: return "\(minutes)m"
        case ..<1440: return "\(minutes / 60)h \(minutes % 60)m"
        default: return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
        }
    }

    static func activity(_ session: ClaudeSession, now: Date) -> String {
        guard let last = session.lastActivity else { return "unknown" }
        return session.isActive(at: now) ? "active" : duration(now.timeIntervalSince(last)) + " ago"
    }

    static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else { return "unknown" }
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func devServers(_ servers: [DevServer]) -> String {
        servers.map { $0.ports.isEmpty ? $0.name : "\($0.name) :\(ProcessMonitor.portList($0.ports))" }.joined(separator: ", ")
    }
}
