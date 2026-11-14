import UserNotifications

@MainActor
final class Notifier {
    private let settings: AppSettings
    private let center: UNUserNotificationCenter?
    private var authorization: Task<Bool, Never>?
    private var pendingDrops: Set<UUID> = []
    private let presenter = ForegroundPresenter()

    init(settings: AppSettings) {
        self.settings = settings
        center = AppSettings.isBundled ? UNUserNotificationCenter.current() : nil
        center?.delegate = presenter
    }

    func dropped(_ connection: Connection, reason: String) {
        guard pendingDrops.insert(connection.id).inserted else { return }
        post(id: "drop-\(connection.id)", title: "\(connection.name) disconnected", body: reason)
    }

    func recovered(_ connection: Connection) {
        guard pendingDrops.remove(connection.id) != nil else { return }
        post(id: "recover-\(connection.id)", title: "\(connection.name) reconnected", body: "Forwards are being restored")
    }

    func forget(_ id: UUID) {
        pendingDrops.remove(id)
    }

    private func post(id: String, title: String, body: String) {
        guard let center, settings.notificationsEnabled else { return }
        let authorization = self.authorization ?? Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        self.authorization = authorization
        Task {
            guard await authorization.value else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

// Without a delegate macOS suppresses banners while a Star Command window is frontmost.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
