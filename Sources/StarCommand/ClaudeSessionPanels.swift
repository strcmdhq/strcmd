import SwiftUI

struct ClaudeInsightsHeader: View {
    let insights: ClaudeInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text(ClaudeFormat.count(insights.sessionCount, "session"))
                Text("\(ClaudeFormat.memory(insights.snapshot.totalMemoryBytes)) with descendants")
                Text("\(insights.activeCount) active")
                Text("\(insights.olderCount) older than \(insights.staleDays) days")
                    .foregroundStyle(insights.olderCount > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if let swap = insights.swapText {
                    Text(swap).foregroundStyle(insights.swapHigh ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer()
            }
            .font(.callout.monospacedDigit())
            HStack(spacing: 16) {
                if !insights.crowds.isEmpty {
                    Text(insights.crowds.map(\.text).joined(separator: " · ")).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                wildcardMenu
            }
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(10)
    }

    @ViewBuilder
    private var wildcardMenu: some View {
        let listeners = insights.snapshot.wildcardListeners
        if !listeners.isEmpty {
            Menu("\(ClaudeFormat.count(listeners.count, "listener")) on all interfaces") {
                ForEach(listeners) { listener in
                    Text(describe(listener))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(listeners.contains { $0.sessionPID != nil } ? .orange : .secondary)
            .help("Reachable from the network, not just this Mac")
        }
    }

    private func describe(_ listener: WildcardListener) -> String {
        let base = "\(listener.name) (\(listener.pid)) on \(listener.socket.address) port \(listener.socket.port)"
        guard let owner = listener.sessionPID else { return base }
        let folder = insights.snapshot.sessions.first { $0.pid == owner }?.folderName ?? "unknown"
        return base + " · session \(owner) in \(folder)"
    }
}

struct ClaudeHelpersRow: View {
    let helpers: [ClaudeSession]
    let now: Date

    var body: some View {
        DisclosureGroup("Background helpers: \(helpers.count) · \(ClaudeFormat.memory(helpers.reduce(0) { $0 + $1.treeMemoryBytes }))") {
            ForEach(helpers) { helper in
                HStack(spacing: 12) {
                    Text("PID \(String(helper.pid))")
                    Text(ClaudeFormat.memory(helper.memoryBytes))
                    Text(ClaudeFormat.duration(helper.age(at: now)))
                    Spacer()
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct ClaudeBulkCloseSheet: View {
    let sessions: [ClaudeSession]
    let now: Date
    let days: Int
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Close \(ClaudeFormat.count(sessions.count, "session")) idle more than \(days) days?").font(.headline)
            Text("Each gets SIGTERM. Active sessions and background helpers are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Table(sessions) {
                TableColumn("PID") { Text(String($0.pid)) }.width(60)
                TableColumn("Folder") { Text(ClaudeFormat.path($0.cwd)).lineLimit(1).truncationMode(.middle).help($0.cwd) }
                TableColumn("Age") { Text(ClaudeFormat.duration($0.age(at: now))) }.width(70)
                TableColumn("Idle") { Text(ClaudeFormat.activity($0, now: now)) }.width(90)
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Close \(ClaudeFormat.count(sessions.count, "session"))", role: .destructive) {
                    confirm()
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}
