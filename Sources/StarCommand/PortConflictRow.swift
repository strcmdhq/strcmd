import SwiftUI

enum PortConflict {
    static func matches(_ error: String?) -> Bool {
        guard let error else { return false }
        return ["address already in use", "address in use"].contains { error.range(of: $0, options: .caseInsensitive) != nil }
    }
}

struct PortConflictRow: View {
    let port: UInt16
    let error: String
    let retry: () async -> Void
    @EnvironmentObject private var monitor: ProcessMonitor
    @State private var holder: Holder = .pending
    @State private var quitError: String?

    private enum Holder {
        case pending, foreign, own(PortListener)
    }

    var body: some View {
        HStack(spacing: 6) {
            switch holder {
            case .pending:
                Text("Looking up port \(String(port))…")
            case .foreign:
                Text("Couldn't find which of your processes holds it")
            case .own(let listener):
                Text("Held by \(listener.name) (\(String(listener.pid)))")
                Button("Quit it") { quit(listener) }.controlSize(.mini)
            }
            if let quitError {
                Text(quitError).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: error) { await lookup() }
    }

    private func lookup() async {
        quitError = nil
        holder = await monitor.lookupListener(port: port).map(Holder.own) ?? .foreign
    }

    private func quit(_ listener: PortListener) {
        quitError = monitor.terminate(pid: listener.pid, force: false)
        guard quitError == nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await retry()
            await lookup()
        }
    }
}
