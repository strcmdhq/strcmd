import Foundation

struct RDSDatabase: Hashable, Identifiable {
    let identifier: String
    let engine: String
    let address: String
    let port: Int
    var id: String { identifier }
}

struct MSKBroker: Hashable {
    let host: String
    let port: Int
}

struct MSKCluster: Hashable, Identifiable {
    let name: String
    let arn: String
    var brokers: [MSKBroker] = []
    var id: String { arn }
}

struct AWSInstance: Hashable, Identifiable {
    let id: String
    let name: String
}

struct AWSInventory: Equatable {
    var databases: [RDSDatabase] = []
    var clusters: [MSKCluster] = []
    var airflows: [String] = []
    var instances: [AWSInstance] = []
    var error: String?

    var summary: String {
        if let error { return error }
        let parts = [(databases.count, "database"), (clusters.count, "Kafka cluster"), (airflows.count, "Airflow environment"), (instances.count, "online instance")]
        return "Found " + parts.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: ", ")
    }
}

enum AWSDiscovery {
    @MainActor private static var cache: [String: AWSInventory] = [:]

    @MainActor
    static func inventory(profile: String, region: String, refresh: Bool = false) async -> AWSInventory {
        let key = "\(profile)|\(region)"
        if !refresh, let cached = cache[key] { return cached }
        let found = await discover(base: ["--profile", profile, "--region", region], profile: profile)
        if found.error == nil { cache[key] = found }
        return found
    }

    private static func discover(base: [String], profile: String) async -> AWSInventory {
        guard let aws = Tools.find("aws") else { return AWSInventory(error: "aws CLI not found") }
        async let databases = call(aws, base + ["rds", "describe-db-instances"])
        async let clusters = call(aws, base + ["kafka", "list-clusters-v2"])
        async let airflows = call(aws, base + ["mwaa", "list-environments"])
        async let online = onlineInstances(aws, base: base, profile: profile, nameFilter: nil)
        var inventory = AWSInventory()
        let results = await [databases, clusters, airflows]
        inventory.databases = results[0].map(parseDatabases) ?? []
        inventory.clusters = results[1].map(parseClusters) ?? []
        inventory.airflows = results[2].map(parseAirflows) ?? []
        inventory.instances = (try? await online) ?? []
        for index in inventory.clusters.indices {
            let arn = inventory.clusters[index].arn
            inventory.clusters[index].brokers = await call(aws, base + ["kafka", "get-bootstrap-brokers", "--cluster-arn", arn]).map(parseBrokers) ?? []
        }
        if results.allSatisfy({ $0 == nil }), inventory.instances.isEmpty {
            let probe = await Tools.capture(aws, base + ["sts", "get-caller-identity"], timeout: 30)
            inventory.error = probe.status == 0 ? "No access to RDS, MSK, MWAA or SSM with \(profile)" : AWSCLI.explain(probe.stderr, profile: profile)
        }
        return inventory
    }

    static func onlineInstances(_ aws: URL, base: [String], profile: String, nameFilter: String?) async throws -> [AWSInstance] {
        let ssm = base + ["ssm", "describe-instance-information", "--filters", "Key=PingStatus,Values=Online", "--output", "json"]
        let ec2 = base + ["ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=running"]
            + (nameFilter.map { ["Name=tag:Name,Values=\($0)"] } ?? [])
        async let ssmResult = Tools.capture(aws, ssm, timeout: 30)
        async let ec2Data = call(aws, ec2)
        let online = await ssmResult
        guard online.status == 0 else {
            throw ToolError(message: AWSCLI.explain(online.stderr, profile: profile, fallback: "Couldn't list SSM instances"))
        }
        return join(online: parseOnline(online.stdout), named: await ec2Data.map(parseNamed) ?? [], requireName: nameFilter != nil)
    }

    static func join(online: [String], named: [AWSInstance], requireName: Bool) -> [AWSInstance] {
        let names = Dictionary(named.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ids = requireName ? online.filter { names[$0] != nil } : online
        return ids.sorted().map { AWSInstance(id: $0, name: names[$0] ?? "") }
    }

    private static func call(_ aws: URL, _ args: [String]) async -> Data? {
        let result = await Tools.capture(aws, args + ["--output", "json"], timeout: 30)
        return result.status == 0 ? result.stdout : nil
    }

    static func parseDatabases(_ data: Data) -> [RDSDatabase] {
        struct Endpoint: Decodable { let Address: String; let Port: Int }
        struct Instance: Decodable { let DBInstanceIdentifier: String; let Engine: String; let Endpoint: Endpoint? }
        struct List: Decodable { let DBInstances: [Instance] }
        return (try? JSONDecoder().decode(List.self, from: data))?.DBInstances.compactMap { instance in
            instance.Endpoint.map { RDSDatabase(identifier: instance.DBInstanceIdentifier, engine: instance.Engine, address: $0.Address, port: $0.Port) }
        } ?? []
    }

    static func parseClusters(_ data: Data) -> [MSKCluster] {
        struct Cluster: Decodable { let ClusterName: String; let ClusterArn: String }
        struct List: Decodable { let ClusterInfoList: [Cluster] }
        return (try? JSONDecoder().decode(List.self, from: data))?.ClusterInfoList.map { MSKCluster(name: $0.ClusterName, arn: $0.ClusterArn) } ?? []
    }

    static func parseBrokers(_ data: Data) -> [MSKBroker] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [] }
        let list = ["BootstrapBrokerString", "BootstrapBrokerStringTls", "BootstrapBrokerStringSaslIam"].lazy.compactMap { root[$0] }.first ?? ""
        return list.split(separator: ",").compactMap { entry in
            guard let colon = entry.lastIndex(of: ":"), let port = Int(entry[entry.index(after: colon)...]) else { return nil }
            return MSKBroker(host: String(entry[..<colon]), port: port)
        }
        .sorted { $0.host < $1.host }
    }

    static func parseAirflows(_ data: Data) -> [String] {
        struct List: Decodable { let Environments: [String] }
        return (try? JSONDecoder().decode(List.self, from: data))?.Environments ?? []
    }

    static func parseOnline(_ data: Data) -> [String] {
        struct Info: Decodable { let InstanceId: String; let PingStatus: String }
        struct List: Decodable { let InstanceInformationList: [Info] }
        return (try? JSONDecoder().decode(List.self, from: data))?.InstanceInformationList.filter { $0.PingStatus == "Online" }.map(\.InstanceId) ?? []
    }

    static func parseNamed(_ data: Data) -> [AWSInstance] {
        struct Tag: Decodable { let Key: String; let Value: String }
        struct Instance: Decodable { let InstanceId: String; let Tags: [Tag]? }
        struct Reservation: Decodable { let Instances: [Instance] }
        struct List: Decodable { let Reservations: [Reservation] }
        let reservations = (try? JSONDecoder().decode(List.self, from: data))?.Reservations ?? []
        return reservations.flatMap(\.Instances).map { instance in
            AWSInstance(id: instance.InstanceId, name: instance.Tags?.first { $0.Key == "Name" }?.Value ?? "")
        }
    }
}
