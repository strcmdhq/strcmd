import Foundation

// One browser sign-in per profile at a time, shared by every connection and forward that hits the expiry.
actor SSOLogin {
    static let shared = SSOLogin()

    // An abandoned sign-in is not re-prompted on every backoff retry; a manual reconnect clears this.
    static let cooldown: TimeInterval = 15 * 60
    static let timeout: TimeInterval = 5 * 60

    private var running: [String: Task<Bool, Never>] = [:]
    private var lastFailure: [String: Date] = [:]

    func signIn(profile: String, log: @escaping SessionLogHandler) async -> Bool {
        if let task = running[profile] { return await task.value }
        if let failed = lastFailure[profile], Date().timeIntervalSince(failed) < Self.cooldown {
            return false
        }
        let task = Task { await Self.run(profile: profile, log: log) }
        running[profile] = task
        let succeeded = await task.value
        running[profile] = nil
        lastFailure[profile] = succeeded ? nil : Date()
        return succeeded
    }

    func forgive(_ profile: String) {
        lastFailure[profile] = nil
    }

    private static func run(profile: String, log: SessionLogHandler) async -> Bool {
        guard let aws = Tools.find("aws") else { return false }
        let args = ["sso", "login", "--profile", profile]
        log(.info, "SSO expired; approve the sign-in in your browser. $ " + Tools.commandLine(aws, args))
        let result = await Tools.run(aws, args, timeout: timeout)
        if result.status == 0 {
            log(.info, "Signed in to \(profile)")
            return true
        }
        log(.error, "SSO sign-in failed: \(Tools.lastLine(result.stderr) ?? "not approved within \(Int(timeout / 60)) minutes")")
        return false
    }
}
