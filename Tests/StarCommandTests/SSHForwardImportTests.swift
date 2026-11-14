import XCTest
@testable import StarCommand

final class SSHForwardImportTests: XCTestCase {
    private func parse(_ text: String) -> [PortForward] {
        ExternalConfig.SSHForwards.parse(lines: text.split(separator: "\n").map(String.init))
    }

    private func route(_ forward: PortForward) -> (ForwardKind, Int, String, Int) {
        (forward.kind, forward.localPort, forward.remoteHost, forward.remotePort)
    }

    func testParsesResolvedForwards() {
        let forwards = parse("""
        dynamicforward 1080
        dynamicforward [127.0.0.1]:1081
        localforward 3000 [localhost]:3000
        localforward [127.0.0.1]:3001 [db.internal]:5432
        localforward [localhost]:3002 [localhost]:3002
        remoteforward 9000 [localhost]:9000
        remoteforward [127.0.0.1]:9001 [localhost]:9001
        hostname example.com
        """)
        XCTAssertEqual(forwards.count, 7)
        XCTAssertEqual(forwards.map(\.kind), [.dynamic, .dynamic, .local, .local, .local, .remote, .remote])
        XCTAssertEqual(forwards[0].localPort, 1080)
        XCTAssertEqual(forwards[1].localPort, 1081)
        XCTAssertTrue(route(forwards[2]) == (.local, 3000, "localhost", 3000))
        XCTAssertTrue(route(forwards[3]) == (.local, 3001, "db.internal", 5432))
        XCTAssertTrue(route(forwards[4]) == (.local, 3002, "localhost", 3002))
        XCTAssertTrue(route(forwards[5]) == (.remote, 9000, "localhost", 9000))
        XCTAssertTrue(route(forwards[6]) == (.remote, 9001, "localhost", 9001))
        XCTAssertTrue(forwards.allSatisfy { $0.label.isEmpty && $0.enabled })
    }

    func testParsesUnbracketedAndIPv6Hosts() {
        let forwards = parse("""
        localforward 127.0.0.1:3000 localhost:3000
        localforward *:3001 db:5432
        localforward [::1]:3002 [::1]:3002
        remoteforward 127.0.0.1:9000 localhost:9000
        dynamicforward 127.0.0.1:1080
        """)
        XCTAssertEqual(forwards.count, 5)
        XCTAssertTrue(route(forwards[0]) == (.local, 3000, "localhost", 3000))
        XCTAssertTrue(route(forwards[1]) == (.local, 3001, "db", 5432))
        XCTAssertTrue(route(forwards[2]) == (.local, 3002, "::1", 3002))
        XCTAssertTrue(route(forwards[3]) == (.remote, 9000, "localhost", 9000))
        XCTAssertEqual(forwards[4].kind, .dynamic)
        XCTAssertEqual(forwards[4].localPort, 1080)
    }

    func testIgnoresUnrelatedAndMalformed() {
        let forwards = parse("""
        forwardagent no
        clearallforwardings no
        localforward abc def
        localforward 3000
        localforward 3000 localhost:abc
        remoteforward
        dynamicforward socks
        user me
        """)
        XCTAssertTrue(forwards.isEmpty)
    }

    func testDedupesRepeatedLines() {
        let forwards = parse("""
        localforward 3000 [localhost]:3000
        localforward [127.0.0.1]:3000 [localhost]:3000
        dynamicforward 1080
        dynamicforward [localhost]:1080
        localforward 3000 [localhost]:3000
        """)
        XCTAssertEqual(forwards.count, 2)
        XCTAssertEqual(forwards.map(\.routeKey), ["local:3000:localhost:3000", "dynamic:1080"])
    }
}
