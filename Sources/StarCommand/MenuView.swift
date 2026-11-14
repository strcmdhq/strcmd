import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var hotKey: HotKeyController
    @Environment(\.openWindow) private var openWindow

    private let maxListHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.connections.isEmpty {
                emptyState
            } else {
                // A ScrollView collapses to nothing in a window-style MenuBarExtra, so only use one when the list is long.
                if estimatedListHeight > maxListHeight {
                    ScrollView { connectionList }.frame(height: maxListHeight)
                } else {
                    connectionList
                }
            }
            Divider()
            StayAwakeSection()
            Divider()
            ToolsSection()
            Divider()
            SystemSection()
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { hotKey.openWindow = { openWindow(id: $0) } }
    }

    private var connectionList: some View {
        VStack(spacing: 12) {
            ForEach(store.connections) { connection in
                ConnectionSection(connection: connection)
            }
        }
        .padding(12)
    }

    private var estimatedListHeight: CGFloat {
        store.connections.reduce(24) { $0 + 60 + CGFloat($1.forwards.count) * 40 }
    }

    private var header: some View {
        HStack {
            Text("Star Command").font(.headline)
            Spacer()
            Button(action: openEditor) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit connections and forwards")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Every port, under command.").foregroundStyle(.secondary)
            Button("Add a connection", action: openEditor)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button("Disconnect All") {
                Task { await manager.disconnectAll() }
            }
            .disabled(manager.wanted.isEmpty)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openEditor() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "editor")
    }
}

private struct StayAwakeSection: View {
    @EnvironmentObject private var awake: AwakeController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stay awake").font(.caption).fontWeight(.medium)
                Spacer()
                Menu {
                    Picker("Mode", selection: $awake.manualMode) {
                        ForEach(AwakeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Duration", selection: $awake.manualDuration) {
                        ForEach(AwakeDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(awake.manualMode.title) · \(awake.manualDuration.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Toggle("", isOn: Binding(
                    get: { awake.isManual },
                    set: { on in
                        if on {
                            awake.enable(mode: awake.manualMode, for: awake.manualDuration.seconds)
                        } else {
                            awake.disable()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if let text = awake.statusText {
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ToolsSection: View {
    @EnvironmentObject private var tools: QuickTools

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Tools").font(.caption).fontWeight(.medium)
                Spacer()
                toolButton("clock.arrow.circlepath", help: "Time Machine: back up now", action: tools.startBackup)
                toolButton("stop.circle", help: "Time Machine: stop backup", action: tools.stopBackup)
                toolButton("person.crop.circle.badge.checkmark", help: "Open Login Items settings", action: tools.openLoginItems)
            }
            if let text = tools.lastResult {
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(tools.running)
            .help(help)
    }
}

private struct SystemSection: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var portText = ""
    @State private var freeResult: String?
    @State private var freeing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("System").font(.caption).fontWeight(.medium)
                Spacer()
                Button("Open Process Monitor", action: openMonitor)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if let system = monitor.system {
                Text("CPU \(ProcessMonitor.percent(system.cpuPercent)) · Memory \(ProcessMonitor.memory(system.memoryUsed)) of \(ProcessMonitor.memory(system.memoryTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Sampling…").font(.caption).foregroundStyle(.secondary)
            }
            ClaudeMenuLine()
            ForEach(monitor.topProcesses) { process in
                HStack {
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(process.cpuPercent, format: .number.precision(.fractionLength(1)))
                        .foregroundStyle(.secondary) + Text("%").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            HStack(spacing: 6) {
                Text("Free a port").font(.caption)
                Spacer()
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 64)
                    .onSubmit(freePort)
                Button("Free", action: freePort)
                    .controlSize(.small)
                    .disabled(port == nil || freeing)
            }
            if let freeResult {
                Text(freeResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var port: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private func freePort() {
        guard let port, !freeing else { return }
        freeing = true
        Task {
            freeResult = await monitor.freePort(port)
            freeing = false
        }
    }

    private func openMonitor() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "processes")
    }
}

private struct ConnectionSection: View {
    let connection: Connection
    @EnvironmentObject private var manager: ConnectionManager
    @EnvironmentObject private var log: LogStore
    @Environment(\.openWindow) private var openWindow

    private var status: ConnectionManager.Status { manager.status(connection.id) }
    private var wanted: Bool { manager.wanted.contains(connection.id) }
    private var activeCount: Int { manager.activeForwards[connection.id]?.count ?? 0 }
    private var enabledCount: Int { connection.forwards.filter(\.enabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Image(systemName: connection.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name).fontWeight(.medium)
                    Text(connection.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .help(connection.subtitle)
                if !connection.forwards.isEmpty {
                    Text("\(activeCount)/\(enabledCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let roundTrip = manager.latency[connection.id] {
                    Text(connection.kind == .ssh ? ConnectionManager.latencyText(roundTrip) : "probe \(ConnectionManager.latencyText(roundTrip))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openLog) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Show log")
                if status == .connecting {
                    ProgressView().controlSize(.small)
                } else if wanted {
                    Button {
                        Task { await manager.reconnect(connection.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reconnect now")
                }
                Toggle("", isOn: Binding(
                    get: { wanted },
                    set: { on in Task { await manager.setWanted(connection.id, on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if case .failed(let reason) = status {
                Text(wanted && connection.autoReconnect ? "\(reason) · retrying" : reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 16)
            }
            ForEach(connection.forwards) { forward in
                ForwardRow(connection: connection, forward: forward)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openLog() {
        log.selectedConnectionID = connection.id
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "log")
    }

    private var statusColor: Color {
        switch status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

private struct ForwardRow: View {
    let connection: Connection
    let forward: PortForward
    @EnvironmentObject private var manager: ConnectionManager
    @State private var copied = false

    private var active: Bool { manager.isActive(forward.id, in: connection.id) }
    private var error: String? { manager.forwardErrors[forward.id] }
    private var portConflict: Bool {
        forward.kind != .remote && PortConflict.matches(error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: active ? "circle.fill" : "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(active ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(forward.displayName).font(.callout)
                    Text(copied ? "Copied" : forward.routeText)
                        .font(.caption.monospaced())
                        .foregroundStyle(copied ? .green : .secondary)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: copy)
                        .help("Click to copy \(forward.copyText)")
                }
                Spacer()
                if active && forward.kind == .local {
                    Button {
                        NSWorkspace.shared.open(URL(string: "http://localhost:\(forward.localPort)")!)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help(forward.awsService == .mwaa ? "Sign in and open Airflow" : "Open in browser")
                }
                Toggle("", isOn: Binding(
                    get: { forward.enabled },
                    set: { manager.setForwardEnabled(connection.id, forward.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 16)
            }
            if forward.awsService == .msk {
                Text(AWSService.kafkaCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
            if portConflict {
                PortConflictRow(port: UInt16(clamping: forward.localPort), error: error ?? "") {
                    await manager.retryForwards(connection.id)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.leading, 16)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(forward.copyText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
