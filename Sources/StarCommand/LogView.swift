import AppKit
import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var log: LogStore
    @State private var follow = true
    @State private var bottomID: UUID?

    private var entries: [LogEntry] {
        log.selectedConnectionID.flatMap { log.entries[$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                Text("No log entries yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entryList
            }
        }
        .navigationTitle("Star Command Log")
        .onAppear {
            if log.selectedConnectionID == nil { log.selectedConnectionID = store.connections.first?.id }
        }
        .onChange(of: log.selectedConnectionID) { _, _ in
            follow = true
            bottomID = entries.last?.id
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Connection", selection: $log.selectedConnectionID) {
                ForEach(store.connections) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 320)
            Spacer()
            Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).disabled(entries.isEmpty)
            Button("Copy All", action: copyAll).disabled(entries.isEmpty)
            Button("Clear") { log.selectedConnectionID.map(log.clear) }.disabled(entries.isEmpty)
        }
        .padding(10)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    Text("\(LogStore.time(entry.date))  \(entry.text)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.level == .error ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .scrollPosition(id: $bottomID, anchor: .bottom)
        .onChange(of: entries.last?.id) { _, id in if follow { bottomID = id } }
        .onChange(of: bottomID) { _, id in follow = id == entries.last?.id }
        .onChange(of: follow) { _, on in if on { bottomID = entries.last?.id } }
        .onAppear { bottomID = entries.last?.id }
    }

    private func copyAll() {
        guard let id = log.selectedConnectionID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text(id), forType: .string)
    }
}
