import XCTest
@testable import StarCommand

final class AWSModelTests: XCTestCase {
    func testOldForwardDecodesAsHostService() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"db","kind":"local","localPort":5433,"remoteHost":"db.internal","remotePort":5432,"enabled":true}"#
        let forward = try JSONDecoder().decode(PortForward.self, from: Data(json.utf8))
        XCTAssertEqual(forward.awsService, .host)
        XCTAssertEqual(forward.awsResource, "")
        XCTAssertEqual(forward.routeText, "localhost:5433 → db.internal:5432")
    }

    func testServiceRoundTrips() throws {
        let original = PortForward(localPort: 5433, remotePort: 5432, awsService: .rds, awsResource: "acme-dev-airbyte-db")
        XCTAssertEqual(try JSONDecoder().decode(PortForward.self, from: JSONEncoder().encode(original)), original)
    }

    func testOldAWSConnectionKeepsInstanceTarget() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","name":"Old","kind":"awsSSM","awsProfile":"acme-dev","awsRegion":"us-east-1","awsTarget":"i-0abc","forwards":[]}"#
        let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        XCTAssertEqual(connection.kind.title, "AWS")
        XCTAssertEqual(JumpHost(setting: connection.awsTarget), .instance("i-0abc"))
    }

    func testRouteTextPerService() {
        XCTAssertEqual(PortForward(localPort: 5433, remotePort: 5432, awsService: .rds, awsResource: "acme-dev-airbyte-db").routeText,
                       "localhost:5433 → rds acme-dev-airbyte-db:5432")
        XCTAssertEqual(PortForward(localPort: 9092, remoteHost: "b-1.acmedevdatapipelin.abc123.c3.kafka.us-east-1.amazonaws.com", remotePort: 9092, awsService: .msk).routeText,
                       "localhost:9092 → msk b-1…:9092")
        XCTAssertEqual(PortForward(localPort: 8081, awsService: .mwaa, awsResource: "acme-dev-mwaa").routeText,
                       "localhost:8081 → airflow acme-dev-mwaa")
        XCTAssertEqual(PortForward(localPort: 8081, awsService: .mwaa, awsResource: "acme-dev-mwaa").displayName, "acme-dev-mwaa")
    }

    func testSelectServiceAppliesDefaults() {
        var forward = PortForward(label: "x", remoteHost: "db", remotePort: 1)
        forward.selectService(.msk)
        XCTAssertEqual(forward.remotePort, 9092)
        XCTAssertEqual(forward.remoteHost, "")
        forward.selectService(.rds)
        XCTAssertEqual(forward.remotePort, 5432)
        forward.selectService(.host)
        XCTAssertEqual(forward.remoteHost, "localhost")
        XCTAssertFalse(AWSService.mwaa.needsSSM)
        XCTAssertTrue(AWSService.allCases.filter { $0 != .mwaa }.allSatisfy(\.needsSSM))
    }
}

final class JumpHostTests: XCTestCase {
    private let ssm = Data(#"""
    {"InstanceInformationList": [
      {"InstanceId": "i-0f00000000000000d", "PingStatus": "Online"},
      {"InstanceId": "i-0600000000000000b", "PingStatus": "Online"},
      {"InstanceId": "i-0400000000000000a", "PingStatus": "Online"},
      {"InstanceId": "i-0700000000000000c", "PingStatus": "Online"},
      {"InstanceId": "i-0dead", "PingStatus": "ConnectionLost"}
    ]}
    """#.utf8)

    private let ec2Filtered = Data(#"""
    {"Reservations": [
      {"Instances": [{"InstanceId": "i-0600000000000000b", "Tags": [{"Key": "Name", "Value": "acme-dev-system-node"}, {"Key": "eks:nodegroup-name", "Value": "system"}]}]},
      {"Instances": [{"InstanceId": "i-0400000000000000a", "Tags": [{"Key": "Name", "Value": "acme-dev-system-node"}]},
                     {"InstanceId": "i-0dead", "Tags": [{"Key": "Name", "Value": "acme-dev-system-node"}]}]}
    ]}
    """#.utf8)

    func testSettingParsing() {
        XCTAssertEqual(JumpHost(setting: " i-0abc "), .instance("i-0abc"))
        XCTAssertEqual(JumpHost(setting: "*-system-node").nameFilter, "*-system-node*")
        XCTAssertEqual(JumpHost(setting: "acme-dev-gitlab*").nameFilter, "acme-dev-gitlab*")
        XCTAssertNil(JumpHost(setting: "").nameFilter)
        XCTAssertNil(JumpHost(setting: "i-0abc").nameFilter)
    }

    func testPatternChoosesFirstOnlineMatch() {
        let online = AWSDiscovery.parseOnline(ssm)
        XCTAssertEqual(online.count, 4)
        let candidates = AWSDiscovery.join(online: online, named: AWSDiscovery.parseNamed(ec2Filtered), requireName: true)
        XCTAssertEqual(candidates.map(\.id), ["i-0400000000000000a", "i-0600000000000000b"])
        XCTAssertEqual(JumpHost.choose(candidates, current: nil), AWSInstance(id: "i-0400000000000000a", name: "acme-dev-system-node"))
        XCTAssertEqual(JumpHost.choose(candidates, current: "i-0600000000000000b")?.id, "i-0600000000000000b", "keeps the instance in use")
        XCTAssertEqual(JumpHost.choose(candidates, current: "i-gone")?.id, "i-0400000000000000a")
        XCTAssertNil(JumpHost.choose([], current: nil))
    }

    func testEmptyPatternUsesAnyOnlineInstance() {
        let candidates = AWSDiscovery.join(online: AWSDiscovery.parseOnline(ssm), named: AWSDiscovery.parseNamed(ec2Filtered), requireName: false)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(JumpHost.choose(candidates, current: nil)?.id, "i-0400000000000000a")
        XCTAssertEqual(candidates.first { $0.id == "i-0700000000000000c" }?.name, "")
    }
}

final class SSMCommandTests: XCTestCase {
    private let base = ["--profile", "acme-dev", "--region", "us-east-1"]

    func testRemoteHostUsesToRemoteHostDocument() {
        XCTAssertEqual(SSMCommand.arguments(base: base, target: "i-1", host: "acme-dev-airbyte-db.x.rds.amazonaws.com", remotePort: 5432, localPort: 5433), base + [
            "ssm", "start-session", "--target", "i-1",
            "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters", "host=acme-dev-airbyte-db.x.rds.amazonaws.com,portNumber=5432,localPortNumber=5433",
        ])
    }

    func testLocalhostTargetsTheInstance() {
        for host in ["localhost", "", " 127.0.0.1 "] {
            XCTAssertEqual(SSMCommand.arguments(base: base, target: "i-1", host: host, remotePort: 22, localPort: 2222).suffix(4), [
                "--document-name", "AWS-StartPortForwardingSession",
                "--parameters", "portNumber=22,localPortNumber=2222",
            ])
        }
    }
}

final class AWSDiscoveryParsingTests: XCTestCase {
    func testDatabases() {
        let json = #"""
        {"DBInstances": [
          {"DBInstanceIdentifier": "acme-dev-airbyte-db", "Engine": "postgres", "Endpoint": {"Address": "acme-dev-airbyte-db.abcdefgh1234.us-east-1.rds.amazonaws.com", "Port": 5432, "HostedZoneId": "Z"}},
          {"DBInstanceIdentifier": "creating", "Engine": "mysql"}
        ]}
        """#
        XCTAssertEqual(AWSDiscovery.parseDatabases(Data(json.utf8)), [
            RDSDatabase(identifier: "acme-dev-airbyte-db", engine: "postgres", address: "acme-dev-airbyte-db.abcdefgh1234.us-east-1.rds.amazonaws.com", port: 5432),
        ])
    }

    func testClustersAndBrokers() {
        let clusters = AWSDiscovery.parseClusters(Data(#"{"ClusterInfoList": [{"ClusterName": "acme-dev-data-pipeline", "ClusterArn": "arn:aws:kafka:us-east-1:1:cluster/acme-dev-data-pipeline/x", "ClusterType": "PROVISIONED"}]}"#.utf8))
        XCTAssertEqual(clusters.map(\.name), ["acme-dev-data-pipeline"])
        let brokers = AWSDiscovery.parseBrokers(Data(#"{"BootstrapBrokerString": "b-1.c.kafka.us-east-1.amazonaws.com:9092,b-3.c.kafka.us-east-1.amazonaws.com:9092,b-2.c.kafka.us-east-1.amazonaws.com:9092"}"#.utf8))
        XCTAssertEqual(brokers.map(\.host), ["b-1.c.kafka.us-east-1.amazonaws.com", "b-2.c.kafka.us-east-1.amazonaws.com", "b-3.c.kafka.us-east-1.amazonaws.com"])
        XCTAssertEqual(Set(brokers.map(\.port)), [9092])
        XCTAssertEqual(AWSDiscovery.parseBrokers(Data(#"{"BootstrapBrokerStringTls": "b-1.c:9094"}"#.utf8)), [MSKBroker(host: "b-1.c", port: 9094)])
    }

    func testAirflowsAndGarbage() {
        XCTAssertEqual(AWSDiscovery.parseAirflows(Data(#"{"Environments": ["acme-dev-mwaa"]}"#.utf8)), ["acme-dev-mwaa"])
        XCTAssertEqual(AWSDiscovery.parseAirflows(Data("garbage".utf8)), [])
        XCTAssertEqual(AWSDiscovery.parseDatabases(Data()), [])
        XCTAssertEqual(AWSDiscovery.parseOnline(Data("{}".utf8)), [])
    }

    func testLiveDiscovery() async throws {
        guard let profile = ProcessInfo.processInfo.environment["AWS_TEST_PROFILE"], !profile.lowercased().contains("breakglass") else {
            throw XCTSkip("set AWS_TEST_PROFILE to run read-only discovery against an account")
        }
        let inventory = await AWSDiscovery.inventory(profile: profile, region: "us-east-1")
        XCTAssertNil(inventory.error)
        let aws = try XCTUnwrap(Tools.find("aws"))
        let setting = JumpHost(setting: JumpHost.defaultPattern)
        let candidates = try await AWSDiscovery.onlineInstances(aws, base: ["--profile", profile, "--region", "us-east-1"], profile: profile, nameFilter: setting.nameFilter)
        let chosen = JumpHost.choose(candidates, current: nil)
        print("""
        live \(profile): \(inventory.summary)
          rds: \(inventory.databases.map { "\($0.identifier) \($0.engine) \($0.port)" })
          msk: \(inventory.clusters.map { "\($0.name) brokers=\($0.brokers.count)" })
          mwaa: \(inventory.airflows)
          online instances: \(inventory.instances.count), matching \(setting.nameFilter ?? "any"): \(candidates.count)
          jump host: \(chosen.map { "\($0.id) (\($0.name))" } ?? "none")
        """)
    }
}

@MainActor
final class AirflowMigrationTests: XCTestCase {
    private let legacy = #"""
    [
      {"enabled": true, "id": "367B6E10-47A8-4064-83D1-C6C3E64F15E5", "label": "Dev", "localPort": 8081, "name": "acme-dev-mwaa", "profile": "acme-dev", "region": "us-east-1"},
      {"enabled": true, "id": "5FC794FE-5BE4-4B17-AAB6-BB3BE66EDE0F", "label": "Staging", "localPort": 8082, "name": "acme-staging-mwaa", "profile": "acme-staging", "region": "us-east-1"},
      {"enabled": true, "id": "FB8D5EA7-F8EE-41E3-B0CC-ED2B28BE20F0", "label": "Prod", "localPort": 8083, "name": "acme-production-mwaa", "profile": "acme-prod", "region": "us-east-1"},
      {"enabled": false, "id": "24C2A357-5252-4A60-90F0-73CDD5BBCF33", "label": "Lakehouse", "localPort": 8084, "name": "surf-lakehouse", "profile": "default", "region": "us-east-1"}
    ]
    """#

    func testMergeCreatesOneConnectionPerProfile() throws {
        var ssh = Connection()
        ssh.name = "Studio"
        let environments = try JSONDecoder().decode([AirflowMigration.Environment].self, from: Data(legacy.utf8))
        let merged = AirflowMigration.merge(environments, into: [ssh])

        XCTAssertEqual(merged.map(\.name), ["Studio", "AWS dev", "AWS staging", "AWS prod", "AWS default"])
        let aws = Array(merged.dropFirst())
        XCTAssertTrue(aws.allSatisfy { $0.kind == .awsSSM && $0.autoReconnect && $0.awsTarget == JumpHost.defaultPattern && $0.awsRegion == "us-east-1" })
        XCTAssertEqual(aws.map(\.connectOnLaunch), [true, true, false, true])
        XCTAssertEqual(aws.map(\.awsProfile), ["acme-dev", "acme-staging", "acme-prod", "default"])
        let forwards = aws.map { try! XCTUnwrap($0.forwards.first) }
        XCTAssertTrue(aws.allSatisfy { $0.forwards.count == 1 })
        XCTAssertEqual(forwards.map(\.label), ["Dev", "Staging", "Prod", "Lakehouse"])
        XCTAssertEqual(forwards.map(\.localPort), [8081, 8082, 8083, 8084])
        XCTAssertEqual(forwards.map(\.enabled), [true, true, true, false])
        XCTAssertEqual(forwards.map(\.awsResource), ["acme-dev-mwaa", "acme-staging-mwaa", "acme-production-mwaa", "surf-lakehouse"])
        XCTAssertTrue(forwards.allSatisfy { $0.awsService == .mwaa && $0.kind == .local })

        XCTAssertEqual(AirflowMigration.merge(environments, into: merged), merged, "running it twice adds nothing")
    }

    func testMergeReusesExistingConnectionAndFillsMissingPorts() {
        var existing = Connection()
        existing.kind = .awsSSM
        existing.awsProfile = "acme-dev"
        existing.forwards = [PortForward(localPort: 8081)]
        let merged = AirflowMigration.merge([.init(label: "Dev", profile: "acme-dev", region: "us-east-1", name: "acme-dev-mwaa", localPort: 0, enabled: nil)], into: [existing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].forwards.last?.localPort, 8082)
        XCTAssertEqual(merged[0].forwards.last?.enabled, true)
    }

    func testConfigStoreMigratesAndArchivesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StarCommandMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("airflow.json"))

        let store = ConfigStore(directory: directory)
        XCTAssertEqual(store.connections.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("airflow.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("airflow.json.migrated").path))
        let saved = try JSONDecoder().decode([Connection].self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        XCTAssertEqual(saved, store.connections)
        XCTAssertEqual(ConfigStore(directory: directory).connections, saved, "a second launch finds nothing to migrate")
    }

    func testUnreadableFileIsLeftInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StarCommandMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("airflow.json"))
        XCTAssertEqual(ConfigStore(directory: directory).connections, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("airflow.json").path))
    }
}
