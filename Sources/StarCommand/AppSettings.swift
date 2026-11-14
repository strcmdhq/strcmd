import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let isBundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var keepAwakeWhileConnected: Bool {
        didSet { defaults.set(keepAwakeWhileConnected, forKey: "keepAwakeWhileConnected") }
    }
    @Published var keepAwakeMode: AwakeMode {
        didSet { defaults.set(keepAwakeMode.rawValue, forKey: "keepAwakeMode") }
    }
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    @Published var claudeStaleDays: Int {
        didSet { defaults.set(claudeStaleDays, forKey: "claudeStaleDays") }
    }

    private let defaults = UserDefaults.standard
    nonisolated static let legacyDomain = "io.blanche.berth"
    nonisolated static let keys = ["notificationsEnabled", "keepAwakeWhileConnected", "keepAwakeMode", "hotkeyEnabled", "claudeStaleDays"]

    init() {
        Self.migrateLegacyDefaults(into: defaults)
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        keepAwakeWhileConnected = defaults.bool(forKey: "keepAwakeWhileConnected")
        keepAwakeMode = defaults.string(forKey: "keepAwakeMode").flatMap(AwakeMode.init(rawValue:)) ?? .systemOnly
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        claudeStaleDays = defaults.object(forKey: "claudeStaleDays") as? Int ?? 7
        refreshLaunchAtLogin()
    }

    static func migrateLegacyDefaults(into defaults: UserDefaults, from legacy: UserDefaults? = UserDefaults(suiteName: legacyDomain)) {
        guard let legacy, !keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        for key in keys {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func refreshLaunchAtLogin() {
        guard Self.isBundled else { return }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard Self.isBundled else { return }
        launchAtLoginError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
