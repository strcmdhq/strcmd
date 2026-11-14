import XCTest
@testable import StarCommand

final class ForwardCopyTests: XCTestCase {
    private func connection(_ forwards: [PortForward], kind: ConnectionKind = .ssh) -> Connection {
        var connection = Connection()
        connection.kind = kind
        connection.forwards = forwards
        return connection
    }

    func testDuplicateInsertsDisabledCopyOnFreePortAfterOriginal() {
        let a = PortForward(label: "db", localPort: 5432, remotePort: 5432)
        let b = PortForward(localPort: 6000)
        var target = connection([a, b])
        target.duplicateForward(a.id)

        XCTAssertEqual(target.forwards.count, 3)
        let copy = target.forwards[1]
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(copy.label, "db copy")
        XCTAssertEqual(copy.localPort, 6001)
        XCTAssertEqual(copy.remotePort, 5432)
        XCTAssertFalse(copy.enabled)
        XCTAssertEqual(target.forwards[2].id, b.id)
    }

    func testDuplicateRemoteKeepsLocalTarget() {
        let remote = PortForward(kind: .remote, localPort: 3000, remotePort: 9000)
        var target = connection([remote])
        target.duplicateForward(remote.id)
        XCTAssertEqual(target.forwards[1].localPort, 3000)
    }

    func testCopyToKubernetesFitsForwardToConnectionKind() {
        let socks = PortForward(kind: .dynamic, localPort: 1080)
        var target = connection([], kind: .kubernetes)
        target.appendCopy(of: socks)
        XCTAssertEqual(target.forwards.first?.kind, .local)
        XCTAssertNotEqual(target.forwards.first?.id, socks.id)
        XCTAssertEqual(target.forwards.first?.enabled, false)
    }

    func testMoveForwardSwapsAndIgnoresEdges() {
        let a = PortForward(localPort: 1), b = PortForward(localPort: 2)
        var target = connection([a, b])
        target.moveForward(a.id, by: -1)
        XCTAssertEqual(target.forwards.map(\.id), [a.id, b.id])
        target.moveForward(a.id, by: 1)
        XCTAssertEqual(target.forwards.map(\.id), [b.id, a.id])
    }

    func testConnectionCopyGetsFreshIDs() {
        var original = connection([PortForward(localPort: 1)])
        original.connectOnLaunch = true
        let copy = original.copy()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.forwards[0].id, original.forwards[0].id)
        XCTAssertFalse(copy.connectOnLaunch)
        XCTAssertFalse(copy.forwards[0].enabled)
        XCTAssertEqual(copy.name, "New connection copy")
    }
}
