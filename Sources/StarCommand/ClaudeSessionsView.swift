import AppKit
import SwiftUI

struct ClaudeSessionsView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: ClaudeSession.ID?
    @State private var sortOrder = [KeyPathComparator(\ClaudeSession.treeMemoryBytes, order: .reverse)]
    @State private var request: CloseRequest?
    @State private var bulkTargets: [ClaudeSession]?
    @State private var lingering: [Int32: Bool] = [:]
    @State private var actionError: String?

    private var now: Date { Date() }
    private var insights: ClaudeInsights { ClaudeInsights(snapshot: monitor.claude, staleDays: settings.claudeStaleDays, now: now) }
    private var rows: [ClaudeSession] { monitor.claude.sessions.sorted(using: sortOrder) }
    private var selected: ClaudeSession? { selection.flatMap { id in monitor.claude.sessions.first { $0.pid == id } } }

    var body: some View {
        VStack(spacing: 0) {
            ClaudeInsightsHeader(insights: insights)
            Divider()
            table
            Divider()
            if let selected {
                details(selected)
                Divider()
            }
            ClaudeHelpersRow(helpers: monitor.claude.helpers, now: now)
            Divider()
            bottomBar
        }
        .navigationTitle("Claude Sessions")
        .alert(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }), presenting: request) { request in
            Button(request.force ? "Force Quit" : "Close", role: .destructive) { perform(request) }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.message) }
        .sheet(item: Binding(get: { bulkTargets.map { BulkTargets(sessions: $0) } }, set: { bulkTargets = $0?.sessions })) { targets in
            ClaudeBulkCloseSheet(sessions: targets.sessions, now: now, days: settings.claudeStaleDays) { closeAll(targets.sessions) }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onChange(of: selection) { actionError = nil }
        .onChange(of: monitor.claude) { lingering = lingering.filter { pid, _ in monitor.claude.sessions.contains { $0.pid == pid } } }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Folder", value: \.cwd) { row in
                HStack(spacing: 6) {
                    Text(ClaudeFormat.path(row.cwd)).lineLimit(1).truncationMode(.middle).help(row.cwd)
                    if row.isActive(at: now) {
                        Text("Active").font(.caption).foregroundStyle(.green)
                    } else if ClaudeSessionRules.isStale(row, days: settings.claudeStaleDays, now: now) {
                        Text("Stale").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("PID", value: \.pid) { Text(String($0.pid)) }.width(60)
            TableColumn("Age", value: \.startSortKey) { Text(ClaudeFormat.duration($0.age(at: now))) }.width(70)
            TableColumn("CPU %", value: \.cpuPercent) { Text($0.cpuPercent, format: .number.precision(.fractionLength(1))) }.width(55)
            TableColumn("Memory", value: \.memoryBytes) { Text(ClaudeFormat.memory($0.memoryBytes)) }.width(80)
            TableColumn("Tree", value: \.treeMemoryBytes) { row in
                Text("\(ClaudeFormat.memory(row.treeMemoryBytes)) · \(Int(row.treeCPUPercent.rounded()))%")
            }
            .width(110)
            TableColumn("Dev servers", value: \.devServerText) { Text($0.devServerText).lineLimit(1).truncationMode(.tail) }.width(min: 80, ideal: 160)
            TableColumn("Last activity", value: \.activitySortKey) { Text(ClaudeFormat.activity($0, now: now)) }.width(90)
        }
    }

    private func details(_ session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.cwd.isEmpty ? "Folder unknown" : session.cwd)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text("PID \(String(session.pid))")
                if let start = session.startTime {
                    Text("Started \(start.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("\(ClaudeFormat.count(session.descendantCount, "descendant")) · \(ClaudeFormat.memory(session.treeMemoryBytes))")
            }
            ForEach(session.devServers) { server in
                Text("\(server.name) (\(String(server.pid)))" + (server.ports.isEmpty ? "" : " listening on \(ProcessMonitor.portList(server.ports))"))
            }
            if let withDevServers = lingering[session.pid] {
                HStack {
                    Text("Still running 5 s after Close").foregroundStyle(.orange)
                    Button("Force Quit…") { request = CloseRequest(session: session, withDevServers: withDevServers, force: true) }
                        .controlSize(.small)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack {
            HStack {
                Button("Reveal Folder") { selected.map(reveal) }
                    .disabled(selected?.cwd.isEmpty ?? true)
                Button("Copy PID") { selected.map(copyPID) }
                Button("Close…") { selected.map { request = CloseRequest(session: $0, withDevServers: false, force: false) } }
                Button("Close with Dev Servers…") { selected.map { request = CloseRequest(session: $0, withDevServers: true, force: false) } }
                    .disabled(selected?.devServers.isEmpty ?? true)
            }
            .disabled(selected == nil)
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Close \(ClaudeFormat.count(insights.stale.count, "session")) idle > \(settings.claudeStaleDays)d…") {
                bulkTargets = insights.stale
            }
            .disabled(insights.stale.isEmpty)
        }
        .padding(10)
    }

    private func perform(_ request: CloseRequest) {
        let errors = monitor.close(request.session, withDevServers: request.withDevServers, force: request.force)
        actionError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        watch([request.session], withDevServers: request.withDevServers)
    }

    private func closeAll(_ confirmed: [ClaudeSession]) {
        let stillStale = Set(insights.stale.map(\.pid))
        let sessions = confirmed.filter { stillStale.contains($0.pid) }
        let errors = sessions.flatMap { monitor.close($0, withDevServers: false, force: false) }
        actionError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        watch(sessions, withDevServers: false)
    }

    private func watch(_ sessions: [ClaudeSession], withDevServers: Bool) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            for session in sessions where ProcessMonitor.isSameProcess(pid: session.pid, startTime: session.startTime) {
                lingering[session.pid] = withDevServers
            }
        }
    }

    private func reveal(_ session: ClaudeSession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
    }

    private func copyPID(_ session: ClaudeSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(session.pid), forType: .string)
    }
}

private struct BulkTargets: Identifiable {
    let sessions: [ClaudeSession]
    var id: [Int32] { sessions.map(\.pid) }
}

private struct CloseRequest {
    let session: ClaudeSession
    let withDevServers: Bool
    let force: Bool

    var title: String {
        "\(force ? "Force quit" : "Close") Claude session \(session.pid)?"
    }

    var message: String {
        let servers = withDevServers && !session.devServers.isEmpty
            ? "\nAlso quits: " + session.devServers.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
            : ""
        return ClaudeFormat.path(session.cwd) + servers + (force ? "\nUnsaved work in the session is lost." : "")
    }
}

extension ClaudeSession {
    var startSortKey: Double { -(startTime?.timeIntervalSince1970 ?? 0) }
    var activitySortKey: Double { lastActivity?.timeIntervalSince1970 ?? 0 }
    var devServerText: String { ClaudeFormat.devServers(devServers) }
}
