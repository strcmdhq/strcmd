import SwiftUI

struct ProcessesView: View {
    @EnvironmentObject private var monitor: ProcessMonitor
    @State private var query = ""
    @State private var selection: ProcessSample.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpuPercent, order: .reverse)]
    @State private var confirmForceQuit = false
    @State private var actionError: String?

    private var rows: [ProcessSample] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? monitor.processes : monitor.processes.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || String($0.pid).contains(needle) || $0.portsText.contains(needle)
        }
        return matching.sorted(using: sortOrder)
    }

    private var selected: ProcessSample? {
        selection.flatMap { id in monitor.processes.first { $0.pid == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        Text(row.name)
                        if row.paused {
                            Text("Paused").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }.width(70)
                TableColumn("CPU %", value: \.cpuPercent) {
                    Text($0.cpuPercent, format: .number.precision(.fractionLength(1)))
                }
                .width(70)
                TableColumn("Memory", value: \.memoryBytes) { Text(ProcessMonitor.memory($0.memoryBytes)) }.width(90)
                TableColumn("Disk", value: \.diskBytesPerSecond) { Text(ProcessMonitor.rate($0.diskBytesPerSecond)) }.width(90)
                TableColumn("Threads", value: \.threadCount) { Text(String($0.threadCount)) }.width(70)
                TableColumn("Ports", value: \.portsText) { Text($0.portsText).lineLimit(1).truncationMode(.tail) }.width(min: 80, ideal: 140)
            }
            Divider()
            if let selected {
                details(selected)
                Divider()
            }
            bottomBar
        }
        .navigationTitle("Processes")
        .alert("Force quit \(selected?.name ?? "process")?", isPresented: $confirmForceQuit) {
            Button("Force Quit", role: .destructive) { terminate(force: true) }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onChange(of: selection) { actionError = nil }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Group {
                if let system = monitor.system {
                    Text("CPU \(ProcessMonitor.percent(system.cpuPercent))")
                    Text("Memory \(ProcessMonitor.memory(system.memoryUsed)) / \(ProcessMonitor.memory(system.memoryTotal))")
                    Text("Load " + system.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " "))
                } else {
                    Text("CPU —")
                    Text("Memory —")
                    Text("Load —")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(10)
    }

    private func details(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(process.path.isEmpty ? process.name : process.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text("Parent: \(process.parentName.isEmpty ? "unknown" : process.parentName) (\(process.parentPID))")
                Text(process.ports.isEmpty ? "Not listening" : "Listening: \(process.portsText)")
            }
            .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack {
            HStack {
                Button("Quit") { terminate(force: false) }
                Button("Force Quit") { confirmForceQuit = true }
                Button(selected?.paused == true ? "Resume" : "Pause", action: togglePaused)
                Menu("Priority") {
                    Button("Normal") { setPriority(0) }
                    Button("Low") { setPriority(10) }
                    Button("Lowest") { setPriority(20) }
                }
                .fixedSize()
            }
            .disabled(selection == nil)
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Text("System processes need a privileged helper, not installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func terminate(force: Bool) {
        guard let selection else { return }
        actionError = monitor.terminate(pid: selection, force: force)
    }

    private func togglePaused() {
        guard let selected else { return }
        actionError = selected.paused ? monitor.resume(pid: selected.pid) : monitor.pause(pid: selected.pid)
    }

    private func setPriority(_ nice: Int32) {
        guard let selection else { return }
        actionError = monitor.setPriority(pid: selection, nice: nice)
    }
}
