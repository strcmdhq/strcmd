import Combine
import Foundation

struct LogEntry: Identifiable {
    enum Level { case info, error }
    let id = UUID()
    let date: Date
    let level: Level
    let text: String
}

@MainActor
final class LogStore: ObservableObject {
    static let capacity = 500
    @Published private(set) var entries: [UUID: [LogEntry]] = [:]
    @Published var selectedConnectionID: UUID?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    func append(_ connectionID: UUID, _ level: LogEntry.Level, _ text: String) {
        entries[connectionID, default: []].append(LogEntry(date: Date(), level: level, text: text))
        let overflow = entries[connectionID]!.count - Self.capacity
        if overflow > 0 { entries[connectionID]!.removeFirst(overflow) }
    }

    func clear(_ connectionID: UUID) {
        entries[connectionID] = nil
    }

    func text(_ connectionID: UUID) -> String {
        (entries[connectionID] ?? []).map { "\(Self.time($0.date))  \($0.text)" }.joined(separator: "\n")
    }

    func handler(for connectionID: UUID) -> SessionLogHandler {
        { [weak self] level, text in
            Task { @MainActor in self?.append(connectionID, level, text) }
        }
    }
}
