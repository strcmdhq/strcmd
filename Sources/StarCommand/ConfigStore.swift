import Foundation
import Combine

@MainActor
final class ConfigStore: ObservableObject {
    @Published var connections: [Connection] = [] {
        didSet { scheduleSave() }
    }

    nonisolated static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Star Command", isDirectory: true)

    private let directory: URL
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL = ConfigStore.directory) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("config.json")
        migrateLegacyConfig()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = decoded
        }
        migrateAirflow()
    }

    func connection(_ id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout Connection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
    }

    private func migrateLegacyConfig() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let support = directory.deletingLastPathComponent()
        for name in ["Berth", "Wormhole", "SSH Manager"] {
            let legacy = support.appendingPathComponent("\(name)/config.json")
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: legacy, to: fileURL)
            return
        }
    }

    // The old file is only archived once the merged connections are safely on disk.
    private func migrateAirflow() {
        let legacy = directory.appendingPathComponent(AirflowMigration.fileName)
        guard let data = try? Data(contentsOf: legacy) else { return }
        guard let environments = try? JSONDecoder().decode([AirflowMigration.Environment].self, from: data) else {
            NSLog("Star Command: left \(legacy.path) in place because it could not be read")
            return
        }
        connections = AirflowMigration.merge(environments, into: connections)
        guard save() else { return }
        try? FileManager.default.moveItem(at: legacy, to: AirflowMigration.archiveURL(for: legacy))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(connections).write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("Star Command: failed to save config: \(error)")
            return false
        }
    }
}
