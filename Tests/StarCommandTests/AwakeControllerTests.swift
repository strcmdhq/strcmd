import XCTest
@testable import StarCommand

@MainActor
final class AwakeControllerTests: XCTestCase {
    func testDurationsInSeconds() {
        XCTAssertNil(AwakeDuration.untilOff.seconds)
        XCTAssertEqual(AwakeDuration.oneHour.seconds, 3600)
        XCTAssertEqual(AwakeDuration.fourHours.seconds, 14400)
        XCTAssertEqual(AwakeDuration.eightHours.seconds, 28800)
    }

    func testCaptions() {
        XCTAssertEqual(AwakeController.caption(mode: .systemOnly, reason: .manual, expiresAt: nil), "Awake · display may sleep")
        XCTAssertEqual(AwakeController.caption(mode: .systemAndDisplay, reason: .manual, expiresAt: nil), "Awake · display stays on")
        XCTAssertEqual(AwakeController.caption(mode: .systemAndDisplay, reason: .connections, expiresAt: nil), "Awake while connections are active")
        let expiry = Date().addingTimeInterval(3600)
        let caption = AwakeController.caption(mode: .systemOnly, reason: .manual, expiresAt: expiry)
        XCTAssertTrue(caption.hasSuffix("until " + expiry.formatted(date: .omitted, time: .shortened)), caption)
    }

    func testLatencyText() {
        XCTAssertEqual(ConnectionManager.latencyText(0.0384), "38 ms")
        XCTAssertEqual(ConnectionManager.latencyText(1.2), "1200 ms")
    }
}
