import XCTest
@testable import StarCommand

final class ForwardKindTests: XCTestCase {
    func testSSHArgumentsPerKind() {
        XCTAssertEqual(
            PortForward(kind: .local, localPort: 3000, remoteHost: "db", remotePort: 5432).sshArguments,
            ["-L", "127.0.0.1:3000:db:5432"]
        )
        XCTAssertEqual(
            PortForward(kind: .remote, localPort: 3000, remoteHost: "localhost", remotePort: 9000).sshArguments,
            ["-R", "127.0.0.1:9000:localhost:3000"]
        )
        XCTAssertEqual(
            PortForward(kind: .dynamic, localPort: 1080, remoteHost: "ignored", remotePort: 1).sshArguments,
            ["-D", "127.0.0.1:1080"]
        )
    }

    func testDecodingWithoutKindIsLocal() throws {
        let json = Data("""
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"x","localPort":1,"remoteHost":"h","remotePort":2,"enabled":true}
        """.utf8)
        let forward = try JSONDecoder().decode(PortForward.self, from: json)
        XCTAssertEqual(forward.kind, .local)
        XCTAssertEqual(forward.label, "x")
        XCTAssertEqual(forward.localPort, 1)
        XCTAssertEqual(forward.remoteHost, "h")
        XCTAssertEqual(forward.remotePort, 2)
        XCTAssertTrue(forward.enabled)
    }

    func testRoundTripKeepsKind() throws {
        let original = PortForward(kind: .remote, localPort: 3000, remotePort: 9000)
        let decoded = try JSONDecoder().decode(PortForward.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .remote)
    }

    func testDisplayNames() {
        XCTAssertEqual(PortForward(kind: .local, localPort: 3000, remotePort: 5432).displayName, "Port 3000")
        XCTAssertEqual(PortForward(kind: .remote, localPort: 3000, remotePort: 9000).displayName, "Remote port 9000")
        XCTAssertEqual(PortForward(kind: .dynamic, localPort: 1080).displayName, "SOCKS 1080")
        XCTAssertEqual(PortForward(label: "Named", kind: .dynamic).displayName, "Named")
    }

    func testRouteText() {
        XCTAssertEqual(PortForward(kind: .local, localPort: 3000, remoteHost: "db", remotePort: 5432).routeText, "localhost:3000 → db:5432")
        XCTAssertEqual(PortForward(kind: .remote, localPort: 3000, remoteHost: "localhost", remotePort: 9000).routeText, "server:9000 → localhost:3000")
        XCTAssertEqual(PortForward(kind: .dynamic, localPort: 1080).routeText, "SOCKS localhost:1080")
    }
}
