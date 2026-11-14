import Foundation

enum AWSService: String, Codable, CaseIterable, Identifiable {
    case host, rds, msk, mwaa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: "Host"
        case .rds: "RDS"
        case .msk: "MSK (Kafka)"
        case .mwaa: "Airflow (MWAA)"
        }
    }

    var symbol: String {
        switch self {
        case .host: "server.rack"
        case .rds: "cylinder.split.1x2"
        case .msk: "arrow.triangle.branch"
        case .mwaa: "wind"
        }
    }

    var routePrefix: String {
        switch self {
        case .host: ""
        case .rds: "rds "
        case .msk: "msk "
        case .mwaa: "airflow "
        }
    }

    var defaultRemotePort: Int? {
        switch self {
        case .host: nil
        case .rds: 5432
        case .msk: 9092
        case .mwaa: nil
        }
    }

    static let kafkaCaption = "Kafka clients also need every broker hostname to resolve here. See README."

    // Managed Airflow web UIs are public and only sign in on their own hostname, so they never go through SSM.
    var needsSSM: Bool { self != .mwaa }
    var usesRemotePort: Bool { self != .mwaa }
}

extension PortForward {
    var awsRouteText: String? {
        switch awsService {
        case .host: nil
        case .rds: "localhost:\(localPort) → rds \(awsResource):\(remotePort)"
        case .msk: "localhost:\(localPort) → msk \(Self.shortHost(remoteHost)):\(remotePort)"
        case .mwaa: "localhost:\(localPort) → airflow \(awsResource)"
        }
    }

    mutating func selectService(_ service: AWSService) {
        guard service != awsService else { return }
        awsService = service
        awsResource = ""
        remoteHost = service == .host ? "localhost" : ""
        if let port = service.defaultRemotePort { remotePort = port }
    }

    private static func shortHost(_ host: String) -> String {
        guard let dot = host.firstIndex(of: ".") else { return host }
        return host[..<dot] + "…"
    }
}

enum JumpHost: Equatable {
    case instance(String)
    case pattern(String)

    static let defaultPattern = "*-system-node"

    init(setting: String) {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        self = trimmed.hasPrefix("i-") ? .instance(trimmed) : .pattern(trimmed)
    }

    var nameFilter: String? {
        guard case .pattern(let pattern) = self, !pattern.isEmpty else { return nil }
        return pattern.hasSuffix("*") ? pattern : pattern + "*"
    }

    // Prefer the instance already in use so one dropped forward does not move every other forward to a new node.
    static func choose(_ candidates: [AWSInstance], current: String?) -> AWSInstance? {
        candidates.first { $0.id == current } ?? candidates.first
    }
}

enum SSMCommand {
    static func arguments(base: [String], target: String, host: String, remotePort: Int, localPort: Int) -> [String] {
        let host = host.trimmingCharacters(in: .whitespaces)
        let toInstance = host.isEmpty || host == "localhost" || host == "127.0.0.1"
        return base + [
            "ssm", "start-session",
            "--target", target,
            "--document-name", toInstance ? "AWS-StartPortForwardingSession" : "AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters", toInstance
                ? "portNumber=\(remotePort),localPortNumber=\(localPort)"
                : "host=\(host),portNumber=\(remotePort),localPortNumber=\(localPort)",
        ]
    }
}

enum AWSCLI {
    static func isSSOExpired(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("token has expired") || text.contains("sso") && text.contains("expired")
    }

    static func explain(_ stderr: String, profile: String, fallback: String = "aws exited with an error") -> String {
        if isSSOExpired(stderr) {
            return "SSO expired. Run: aws sso login --profile \(profile)"
        }
        if stderr.contains("AccessDenied") { return "Access denied for \(profile)" }
        return Tools.lastLine(stderr) ?? fallback
    }
}
