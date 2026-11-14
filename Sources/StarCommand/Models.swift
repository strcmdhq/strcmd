import Foundation

enum ForwardKind: String, Codable, CaseIterable, Identifiable {
    case local, remote, dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "SOCKS"
        }
    }

    var usesRemoteHost: Bool { self != .dynamic }
    var usesRemotePort: Bool { self != .dynamic }
}

struct PortForward: Identifiable, Hashable {
    var id = UUID()
    var label = ""
    var kind = ForwardKind.local
    var localPort = 8080
    var remoteHost = "localhost"
    var remotePort = 8080
    var enabled = true
    var awsService = AWSService.host
    var awsResource = ""

    var displayName: String {
        guard label.isEmpty else { return label }
        if awsService != .host, !awsResource.isEmpty { return awsResource }
        return switch kind {
        case .local: "Port \(localPort)"
        case .remote: "Remote port \(remotePort)"
        case .dynamic: "SOCKS \(localPort)"
        }
    }

    var routeText: String {
        if let route = awsRouteText { return route }
        return switch kind {
        case .local: "localhost:\(localPort) → \(remoteHost):\(remotePort)"
        case .remote: "server:\(remotePort) → \(remoteHost):\(localPort)"
        case .dynamic: "SOCKS localhost:\(localPort)"
        }
    }

    var routeKey: String {
        switch kind {
        case .local: "local:\(localPort):\(remoteHost):\(remotePort)"
        case .remote: "remote:\(remotePort):\(remoteHost):\(localPort)"
        case .dynamic: "dynamic:\(localPort)"
        }
    }

    var copyText: String { "localhost:\(localPort)" }

    // Copies start disabled so they never race the original for the same port.
    func copy() -> PortForward {
        var copy = self
        copy.id = UUID()
        copy.enabled = false
        if !label.isEmpty { copy.label = "\(label) copy" }
        return copy
    }

    var sshArguments: [String] {
        switch kind {
        case .local: ["-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"]
        case .remote: ["-R", "127.0.0.1:\(remotePort):\(remoteHost):\(localPort)"]
        case .dynamic: ["-D", "127.0.0.1:\(localPort)"]
        }
    }
}

extension PortForward: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PortForward()
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? defaults.label
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? defaults.kind
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? defaults.localPort
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? defaults.remoteHost
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? defaults.remotePort
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        awsService = try c.decodeIfPresent(AWSService.self, forKey: .awsService) ?? defaults.awsService
        awsResource = try c.decodeIfPresent(String.self, forKey: .awsResource) ?? defaults.awsResource
    }
}

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case ssh, kubernetes, awsSSM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .kubernetes: "Kubernetes"
        case .awsSSM: "AWS"
        }
    }

    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .kubernetes: "helm"
        case .awsSSM: "cloud"
        }
    }

    var remoteFieldTitle: String {
        switch self {
        case .ssh: "Remote host"
        case .kubernetes, .awsSSM: "Resource"
        }
    }

    var remoteFieldPrompt: String {
        switch self {
        case .ssh: "localhost"
        case .kubernetes: "svc/name, deploy/name, or pod/name"
        case .awsSSM: "host the jump host can reach, or localhost"
        }
    }
}

struct Connection: Identifiable, Hashable {
    var id = UUID()
    var name = "New connection"
    var kind = ConnectionKind.ssh
    var destination = ""
    var kubeContext = ""
    var kubeNamespace = "default"
    var awsProfile = "default"
    var awsRegion = "us-east-1"
    var awsTarget = ""
    var forwards: [PortForward] = []
    var connectOnLaunch = false
    var autoReconnect = true
    var autoSSOLogin = true

    var subtitle: String {
        switch kind {
        case .ssh: destination
        case .kubernetes: "\(kubeContext) · \(kubeNamespace)"
        case .awsSSM: "\(awsProfile) · \(awsRegion)"
        }
    }

    var identity: String {
        switch kind {
        case .ssh: "ssh:\(destination)"
        case .kubernetes: "kube:\(kubeContext):\(kubeNamespace)"
        case .awsSSM: "aws:\(awsProfile):\(awsRegion):\(awsTarget)"
        }
    }

    var awsBaseArguments: [String] {
        ["--profile", awsProfile, "--region", awsRegion]
    }

    func nextFreeLocalPort() -> Int {
        let used = Set(forwards.map(\.localPort))
        var port = (forwards.map(\.localPort).max() ?? 8079) + 1
        while used.contains(port) { port += 1 }
        return port
    }

    func copy() -> Connection {
        var copy = self
        copy.id = UUID()
        copy.name = "\(name) copy"
        copy.connectOnLaunch = false
        copy.forwards = forwards.map { $0.copy() }
        return copy
    }

    func fitted(_ forward: PortForward) -> PortForward {
        var forward = forward
        if kind != .awsSSM { forward.selectService(.host) }
        if kind != .ssh { forward.kind = .local }
        return forward
    }

    mutating func duplicateForward(_ id: UUID) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        var copy = forwards[index].copy()
        if copy.kind != .remote { copy.localPort = nextFreeLocalPort() }
        forwards.insert(copy, at: index + 1)
    }

    mutating func appendCopy(of forward: PortForward) {
        forwards.append(fitted(forward.copy()))
    }

    mutating func moveForward(_ id: UUID, by offset: Int) {
        guard let index = forwards.firstIndex(where: { $0.id == id }),
              forwards.indices.contains(index + offset) else { return }
        forwards.swapAt(index, index + offset)
    }
}

extension Connection: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Connection()
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? defaults.kind
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? defaults.destination
        kubeContext = try c.decodeIfPresent(String.self, forKey: .kubeContext) ?? defaults.kubeContext
        kubeNamespace = try c.decodeIfPresent(String.self, forKey: .kubeNamespace) ?? defaults.kubeNamespace
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile) ?? defaults.awsProfile
        awsRegion = try c.decodeIfPresent(String.self, forKey: .awsRegion) ?? defaults.awsRegion
        awsTarget = try c.decodeIfPresent(String.self, forKey: .awsTarget) ?? defaults.awsTarget
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        connectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? defaults.connectOnLaunch
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? defaults.autoReconnect
        autoSSOLogin = try c.decodeIfPresent(Bool.self, forKey: .autoSSOLogin) ?? defaults.autoSSOLogin
    }
}
