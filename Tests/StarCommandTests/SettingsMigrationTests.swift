import XCTest
@testable import StarCommand

@MainActor
final class SettingsMigrationTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "strcmd-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCopiesBerthSettingsOnFirstLaunch() {
        let legacy = suite(), current = suite()
        legacy.set(false, forKey: "hotkeyEnabled")
        legacy.set(3, forKey: "claudeStaleDays")
        AppSettings.migrateLegacyDefaults(into: current, from: legacy)
        XCTAssertEqual(current.object(forKey: "hotkeyEnabled") as? Bool, false)
        XCTAssertEqual(current.integer(forKey: "claudeStaleDays"), 3)
    }

    func testLeavesExistingSettingsAlone() {
        let legacy = suite(), current = suite()
        legacy.set(3, forKey: "claudeStaleDays")
        current.set(true, forKey: "hotkeyEnabled")
        AppSettings.migrateLegacyDefaults(into: current, from: legacy)
        XCTAssertNil(current.object(forKey: "claudeStaleDays"))
    }
}
