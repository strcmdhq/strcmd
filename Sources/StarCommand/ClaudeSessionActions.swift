import Foundation

extension ProcessMonitor {
    func close(_ session: ClaudeSession, withDevServers: Bool, force: Bool) -> [String] {
        let targets = (withDevServers ? session.devServers.map { ($0.pid, $0.name, $0.startTime) } : []) + [(session.pid, "claude", session.startTime)]
        return targets.compactMap { pid, name, startTime in
            guard Self.isSameProcess(pid: pid, startTime: startTime) else { return nil }
            return terminate(pid: pid, force: force).map { "\(name) (\(pid)): \($0)" }
        }
    }

    nonisolated static func isSameProcess(pid: Int32, startTime: Date?) -> Bool {
        guard let startTime, let identity = ProcInfo.identity(pid: pid) else { return false }
        return identity.startTime == startTime
    }
}
