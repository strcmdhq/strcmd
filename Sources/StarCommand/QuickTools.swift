import Foundation

@MainActor
final class QuickTools: ObservableObject {
    @Published private(set) var lastResult: String?
    @Published private(set) var running = false

    private let settings: AppSettings
    private var clearTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func startBackup() { runTmutil("startbackup", success: "Backup started") }

    func stopBackup() { runTmutil("stopbackup", success: "Backup stopped") }

    func openLoginItems() { settings.openLoginItemsSettings() }

    private func runTmutil(_ verb: String, success: String) {
        guard !running else { return }
        running = true
        Task {
            let result = await Tools.run(URL(fileURLWithPath: "/usr/bin/tmutil"), [verb], timeout: 20)
            running = false
            show(result.status == 0 ? success : (Tools.firstLine(result.stderr) ?? "tmutil exited with status \(result.status)"))
        }
    }

    private func show(_ text: String) {
        lastResult = text
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.lastResult = nil
        }
    }
}
