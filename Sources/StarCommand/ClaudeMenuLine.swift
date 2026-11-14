import AppKit
import SwiftUI

struct ClaudeMenuLine: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private var insights: ClaudeInsights {
        ClaudeInsights(snapshot: monitor.claude, staleDays: settings.claudeStaleDays, now: Date())
    }

    var body: some View {
        if !monitor.claude.sessions.isEmpty {
            Button(action: open) {
                HStack {
                    Text(insights.menuText)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption.monospacedDigit())
            .foregroundStyle(insights.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .help(insights.warning ? "Stale sessions or high swap. Open Claude Sessions" : "Open Claude Sessions")
        }
    }

    private func open() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "claude-sessions")
    }
}
