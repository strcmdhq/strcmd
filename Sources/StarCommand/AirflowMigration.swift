import Foundation

// Airflow environments used to live in their own airflow.json; they are now MWAA forwards on AWS connections.
enum AirflowMigration {
    struct Environment: Decodable {
        var label: String
        var profile: String
        var region: String
        var name: String
        var localPort: Int?
        var enabled: Bool?
    }

    static let fileName = "airflow.json"

    static func merge(_ environments: [Environment], into connections: [Connection]) -> [Connection] {
        var result = connections
        var used = Set(connections.flatMap(\.forwards).map(\.localPort))
        for environment in environments {
            let index = result.firstIndex { $0.kind == .awsSSM && $0.awsProfile == environment.profile && $0.awsRegion == environment.region }
                ?? appendConnection(for: environment, to: &result)
            guard !result[index].forwards.contains(where: { $0.awsService == .mwaa && $0.awsResource == environment.name }) else { continue }
            var forward = PortForward(label: environment.label, enabled: environment.enabled ?? true, awsService: .mwaa, awsResource: environment.name)
            forward.remoteHost = ""
            forward.localPort = environment.localPort.flatMap { $0 > 0 ? $0 : nil } ?? nextPort(after: 8080, avoiding: used)
            forward.remotePort = forward.localPort
            used.insert(forward.localPort)
            result[index].forwards.append(forward)
        }
        return result
    }

    static func connectionName(profile: String) -> String {
        "AWS " + (profile.split(separator: "-").last.map(String.init) ?? profile)
    }

    private static func appendConnection(for environment: Environment, to connections: inout [Connection]) -> Int {
        var connection = Connection()
        connection.name = connectionName(profile: environment.profile)
        connection.kind = .awsSSM
        connection.awsProfile = environment.profile
        connection.awsRegion = environment.region
        connection.awsTarget = JumpHost.defaultPattern
        connection.connectOnLaunch = !environment.profile.lowercased().contains("prod")
        connection.autoReconnect = true
        connections.append(connection)
        return connections.count - 1
    }

    private static func nextPort(after port: Int, avoiding used: Set<Int>) -> Int {
        var port = port + 1
        while used.contains(port) { port += 1 }
        return port
    }

    static func archiveURL(for file: URL) -> URL {
        let archive = file.appendingPathExtension("migrated")
        guard FileManager.default.fileExists(atPath: archive.path) else { return archive }
        return file.appendingPathExtension("migrated-\(Int(Date().timeIntervalSince1970))")
    }
}
