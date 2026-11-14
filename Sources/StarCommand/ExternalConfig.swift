import Foundation

enum ExternalConfig {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func sshAliases() -> [String] {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8) else { return [] }
        var aliases: [String] = []
        for line in text.split(separator: "\n") {
            let tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count > 1, tokens[0].lowercased() == "host" else { continue }
            for token in tokens.dropFirst() where !token.contains(where: { "*?!".contains($0) }) {
                aliases.append(String(token))
            }
        }
        return aliases
    }

    static func awsProfiles() -> [String] {
        var profiles: [String] = []
        for (file, prefix) in [(".aws/config", "profile "), (".aws/credentials", "")] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
                var name = String(trimmed.dropFirst().dropLast())
                if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
                if !profiles.contains(name) { profiles.append(name) }
            }
        }
        return profiles
    }

    static func kubeContexts() async -> [String] {
        await kubectlLines(["config", "get-contexts", "-o", "name"])
    }

    static func kubeNamespaces(context: String) async -> [String] {
        await kubectlLines(["--context", context, "--request-timeout=15s", "get", "namespaces", "-o", "name"])
            .map { $0.replacingOccurrences(of: "namespace/", with: "") }
    }

    static func kubeResources(context: String, namespace: String) async -> [KubeResource] {
        let args = ["--context", context, "--namespace", namespace, "--request-timeout=15s", "get", "svc,deploy,pod", "-o", "json"]
        guard let data = await kubectlOutput(args),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap(KubeResource.init(item:))
    }

    private static func kubectlLines(_ args: [String]) async -> [String] {
        guard let data = await kubectlOutput(args) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func kubectlOutput(_ args: [String]) async -> Data? {
        guard let kubectl = Tools.find("kubectl") else { return nil }
        let result = await Tools.capture(kubectl, args)
        return result.status == 0 ? result.stdout : nil
    }
}

extension ExternalConfig {
    enum SSHForwards {
        static func resolve(destination: String) async throws -> [PortForward] {
            let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
            let result = await Tools.capture(ssh, ["-G", destination], timeout: 10)
            guard result.status == 0 else {
                throw ToolError(message: Tools.lastLine(result.stderr) ?? "ssh -G exited with status \(result.status)")
            }
            return parse(lines: String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        }

        static func parse(lines: [String]) -> [PortForward] {
            var seen = Set<String>()
            return lines.compactMap(forward(from:)).filter { seen.insert($0.routeKey).inserted }
        }

        private static func forward(from line: String) -> PortForward? {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let key = tokens.first?.lowercased() else { return nil }
            switch key {
            case "localforward":
                guard tokens.count >= 3, let listen = splitHostPort(tokens[1]), let target = splitHostPort(tokens[2]) else { return nil }
                return PortForward(kind: .local, localPort: listen.port, remoteHost: target.host ?? "localhost", remotePort: target.port)
            case "remoteforward":
                guard tokens.count >= 3, let listen = splitHostPort(tokens[1]), let target = splitHostPort(tokens[2]) else { return nil }
                return PortForward(kind: .remote, localPort: target.port, remoteHost: target.host ?? "localhost", remotePort: listen.port)
            case "dynamicforward":
                guard tokens.count >= 2, let listen = splitHostPort(tokens[1]) else { return nil }
                return PortForward(kind: .dynamic, localPort: listen.port)
            default:
                return nil
            }
        }

        private static func splitHostPort(_ token: String) -> (host: String?, port: Int)? {
            guard let colon = token.lastIndex(of: ":") else {
                return Int(token).map { (nil, $0) }
            }
            guard let port = Int(token[token.index(after: colon)...]) else { return nil }
            var host = String(token[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            return (host, port)
        }
    }
}

struct KubeResource: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case service = "svc", deployment = "deploy", pod

        var title: String {
            switch self {
            case .service: "Services"
            case .deployment: "Deployments"
            case .pod: "Pods"
            }
        }
    }

    let kind: Kind
    let name: String
    let ports: [Int]

    var id: String { reference }
    var reference: String { "\(kind.rawValue)/\(name)" }

    init?(item: [String: Any]) {
        guard let metadata = item["metadata"] as? [String: Any],
              let name = metadata["name"] as? String,
              let spec = item["spec"] as? [String: Any] else { return nil }
        self.name = name
        let found: [Int]
        switch item["kind"] as? String {
        case "Service":
            kind = .service
            found = ((spec["ports"] as? [[String: Any]]) ?? []).compactMap { $0["port"] as? Int }
        case "Deployment":
            kind = .deployment
            let template = (spec["template"] as? [String: Any])?["spec"] as? [String: Any]
            found = Self.containerPorts(template)
        case "Pod":
            kind = .pod
            found = Self.containerPorts(spec)
        default:
            return nil
        }
        var seen = Set<Int>()
        ports = found.filter { seen.insert($0).inserted }
    }

    private static func containerPorts(_ podSpec: [String: Any]?) -> [Int] {
        ((podSpec?["containers"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["ports"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["containerPort"] as? Int }
    }
}
