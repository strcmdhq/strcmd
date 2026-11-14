import SwiftUI

enum EditorSelection: Hashable {
    case general
    case connection(UUID)
}

struct EditorView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var selection: EditorSelection? = .general

    private var selectedConnectionID: UUID? {
        if case .connection(let id) = selection { id } else { nil }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("General", systemImage: "gearshape").tag(EditorSelection.general)
                }
                Section("Connections") {
                    ForEach(store.connections) { connection in
                        Label(connection.name, systemImage: connection.kind.symbol)
                            .tag(EditorSelection.connection(connection.id))
                            .contextMenu {
                                Button("Duplicate") { duplicate(connection.id) }
                                Button("Delete", role: .destructive) { remove(connection.id) }
                            }
                    }
                    .onMove { store.connections.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Menu {
                    ForEach(ConnectionKind.allCases) { kind in
                        Button(kind.title) { addConnection(kind) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add connection")
                Button { selectedConnectionID.map(remove) } label: { Image(systemName: "minus") }
                    .disabled(selectedConnectionID == nil)
                    .help("Remove connection")
                Button { selectedConnectionID.map(duplicate) } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(selectedConnectionID == nil)
                    .help("Duplicate connection")
            }
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView()
            case .connection(let id):
                if let index = store.connections.firstIndex(where: { $0.id == id }) {
                    ConnectionForm(connection: $store.connections[index])
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
        .onAppear {
            if selection == .general, let first = store.connections.first { selection = .connection(first.id) }
        }
    }

    private var placeholder: some View {
        Text("Select a connection, or add one with +")
            .foregroundStyle(.secondary)
    }

    private func addConnection(_ kind: ConnectionKind) {
        var connection = Connection()
        connection.kind = kind
        if kind == .awsSSM { connection.awsTarget = JumpHost.defaultPattern }
        store.connections.append(connection)
        selection = .connection(connection.id)
    }

    private func remove(_ id: UUID) {
        store.connections.removeAll { $0.id == id }
        if selectedConnectionID == id {
            selection = store.connections.first.map { .connection($0.id) } ?? .general
        }
    }

    private func duplicate(_ id: UUID) {
        guard let index = store.connections.firstIndex(where: { $0.id == id }) else { return }
        let copy = store.connections[index].copy()
        store.connections.insert(copy, at: index + 1)
        selection = .connection(copy.id)
    }
}

private struct ConnectionForm: View {
    @EnvironmentObject private var store: ConfigStore
    @Binding var connection: Connection
    @State private var kubeContexts: [String] = []
    @State private var kubeNamespaces: [String] = []
    @State private var kubeResources: [KubeResource] = []
    @State private var awsInventory = AWSInventory()
    @State private var discovering = false
    @State private var importResult = ""
    @State private var importingID: UUID?
    private let sshAliases = ExternalConfig.sshAliases()
    private let awsProfiles = ExternalConfig.awsProfiles()

    private enum Column {
        static let kind: CGFloat = 100
        static let service: CGFloat = 150
        static let label: CGFloat = 160
        static let port: CGFloat = 84
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Name", text: $connection.name)
                Picker("Type", selection: $connection.kind) {
                    ForEach(ConnectionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                kindFields
                Toggle("Connect when the app launches", isOn: $connection.connectOnLaunch)
                Toggle("Reconnect automatically after drops, sleep, or network changes", isOn: $connection.autoReconnect)
                if connection.kind == .awsSSM {
                    Toggle("Sign in again in the browser when SSO expires", isOn: $connection.autoSSOLogin)
                }
            }

            Section("Port forwards") {
                if connection.forwards.isEmpty {
                    Text("No forwards yet").foregroundStyle(.secondary)
                } else {
                    forwardsGrid
                }
                Button(action: addForward) {
                    Label("Add forward", systemImage: "plus")
                }
            }

            Section {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(connection.name)
        .onChange(of: connection.kind) {
            if connection.kind == .awsSSM, connection.awsTarget.isEmpty {
                connection.awsTarget = JumpHost.defaultPattern
            }
            connection.forwards = connection.forwards.map(connection.fitted)
        }
        .onChange(of: connection.destination) { importResult = "" }
        .task {
            kubeContexts = await ExternalConfig.kubeContexts()
        }
        .task(id: connection.kind == .kubernetes ? connection.kubeContext : "") {
            kubeNamespaces = []
            guard connection.kind == .kubernetes, !connection.kubeContext.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            kubeNamespaces = await ExternalConfig.kubeNamespaces(context: connection.kubeContext)
        }
        .task(id: connection.kind == .kubernetes ? "\(connection.kubeContext)|\(connection.kubeNamespace)" : "") {
            kubeResources = []
            guard connection.kind == .kubernetes, !connection.kubeContext.isEmpty, !connection.kubeNamespace.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            kubeResources = await ExternalConfig.kubeResources(context: connection.kubeContext, namespace: connection.kubeNamespace)
        }
        .task(id: connection.kind == .awsSSM ? "\(connection.awsProfile)|\(connection.awsRegion)" : "") {
            awsInventory = AWSInventory()
            guard connection.kind == .awsSSM else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await discoverAWS(refresh: false)
        }
    }

    private var forwardsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                if connection.kind == .ssh { columnHeader("Kind") }
                if connection.kind == .awsSSM { columnHeader("Service") }
                columnHeader("Label")
                columnHeader("Local port")
                columnHeader(connection.kind.remoteFieldTitle)
                columnHeader("Remote port")
                columnHeader("On")
                columnHeader("")
            }
            ForEach($connection.forwards) { $forward in
                GridRow {
                    if connection.kind == .ssh {
                        Picker("Kind", selection: $forward.kind) {
                            ForEach(ForwardKind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: Column.kind)
                    }
                    if connection.kind == .awsSSM {
                        AWSServicePicker(forward: $forward)
                            .frame(width: Column.service)
                    }
                    TextField("Label", text: $forward.label)
                        .frame(width: Column.label)
                    TextField("Local port", value: $forward.localPort, format: .number.grouping(.never))
                        .frame(width: Column.port)
                        .help(forward.kind == .remote ? "Port on this Mac that the server's port will reach" : "Port on this Mac")
                    remoteHostCell($forward)
                    remotePortCell($forward)
                    Toggle("Enabled", isOn: $forward.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Enabled")
                    HStack(spacing: 6) {
                        forwardActions(forward)
                        Button {
                            connection.forwards.removeAll { $0.id == forward.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove forward")
                    }
                }
                if connection.kind == .awsSSM, forward.awsService == .msk {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(AWSService.kafkaCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(6)
                    }
                }
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }

    private func forwardActions(_ forward: PortForward) -> some View {
        let position = connection.forwards.firstIndex { $0.id == forward.id } ?? 0
        let others = store.connections.filter { $0.id != connection.id }
        return Menu {
            Button("Duplicate") { connection.duplicateForward(forward.id) }
            Menu("Copy to") {
                ForEach(others) { target in
                    Button(target.name) { store.update(target.id) { $0.appendCopy(of: forward) } }
                }
            }
            .disabled(others.isEmpty)
            Divider()
            Button("Move up") { connection.moveForward(forward.id, by: -1) }
                .disabled(position == 0)
            Button("Move down") { connection.moveForward(forward.id, by: 1) }
                .disabled(position == connection.forwards.count - 1)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Duplicate, copy, or reorder")
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private var unusedCell: some View {
        Text("—").foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func remoteHostCell(_ forward: Binding<PortForward>) -> some View {
        if connection.kind == .awsSSM {
            AWSResourceField(forward: forward, inventory: awsInventory)
        } else if forward.wrappedValue.kind.usesRemoteHost {
            HStack(spacing: 4) {
                TextField(connection.kind.remoteFieldTitle, text: forward.remoteHost, prompt: Text(connection.kind.remoteFieldPrompt))
                if connection.kind == .kubernetes {
                    resourcePicker(for: forward)
                }
            }
        } else {
            unusedCell.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func remotePortCell(_ forward: Binding<PortForward>) -> some View {
        if forward.wrappedValue.kind.usesRemotePort, connection.kind != .awsSSM || forward.wrappedValue.awsService.usesRemotePort {
            HStack(spacing: 4) {
                TextField("Remote port", value: forward.remotePort, format: .number.grouping(.never))
                    .frame(width: Column.port)
                    .help(forward.wrappedValue.kind == .remote ? "Port opened on the server" : "Port on the remote host")
                if connection.kind == .kubernetes {
                    suggestions(portsForResource(forward.wrappedValue.remoteHost).map(String.init), into: Binding(
                        get: { String(forward.wrappedValue.remotePort) },
                        set: { forward.wrappedValue.remotePort = Int($0) ?? forward.wrappedValue.remotePort }
                    ), help: "Ports exposed by the resource")
                }
            }
        } else {
            unusedCell.frame(width: Column.port, alignment: .leading)
        }
    }

    private var isBreakglass: Bool {
        connection.awsProfile.lowercased().contains("breakglass")
    }

    private func discoverAWS(refresh: Bool) async {
        guard !isBreakglass, !connection.awsProfile.isEmpty, !connection.awsRegion.isEmpty else { return }
        let key = (connection.awsProfile, connection.awsRegion)
        discovering = true
        let found = await AWSDiscovery.inventory(profile: key.0, region: key.1, refresh: refresh)
        discovering = false
        if (connection.awsProfile, connection.awsRegion) == key { awsInventory = found }
    }

    private func addForward() {
        var forward = PortForward()
        forward.localPort = connection.nextFreeLocalPort()
        forward.remotePort = forward.localPort
        if connection.kind == .kubernetes { forward.remoteHost = "" }
        connection.forwards.append(forward)
    }

    private func importForwards() {
        let id = connection.id
        importingID = id
        Task {
            var result: String
            do {
                let resolved = try await ExternalConfig.SSHForwards.resolve(destination: connection.destination)
                var added = 0
                store.update(id) { target in
                    let existing = Set(target.forwards.map(\.routeKey))
                    let imported = resolved.filter { !existing.contains($0.routeKey) }
                    target.forwards.append(contentsOf: imported)
                    added = imported.count
                }
                result = added == 0 ? "Nothing new to import" : "Imported \(added) forward\(added == 1 ? "" : "s")"
            } catch {
                result = error.localizedDescription
            }
            if importingID == id { importingID = nil }
            if connection.id == id { importResult = result }
        }
    }

    private func portsForResource(_ reference: String) -> [Int] {
        kubeResources.first { $0.reference == reference }?.ports ?? []
    }

    @ViewBuilder
    private func resourcePicker(for forward: Binding<PortForward>) -> some View {
        if !kubeResources.isEmpty {
            Menu {
                ForEach(KubeResource.Kind.allCases, id: \.self) { kind in
                    let matching = kubeResources.filter { $0.kind == kind }
                    if !matching.isEmpty {
                        Section(kind.title) {
                            ForEach(matching) { resource in
                                Button(resource.name) {
                                    forward.wrappedValue.remoteHost = resource.reference
                                    if let port = resource.ports.first, resource.ports.count == 1 {
                                        forward.wrappedValue.remotePort = port
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Services, deployments, and pods in \(connection.kubeNamespace)")
        }
    }

    @ViewBuilder
    private var kindFields: some View {
        switch connection.kind {
        case .ssh:
            suggestedField("SSH destination", text: $connection.destination, prompt: "user@hostname or ~/.ssh/config alias", values: sshAliases, help: "Hosts from ~/.ssh/config")
            HStack(spacing: 8) {
                Button("Import forwards from SSH config", action: importForwards)
                    .disabled(importingID == connection.id || connection.destination.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(importResult).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .kubernetes:
            suggestedField("Context", text: $connection.kubeContext, values: kubeContexts, help: "Contexts from kubectl")
            suggestedField("Namespace", text: $connection.kubeNamespace, values: kubeNamespaces, help: "Namespaces in the selected context")
        case .awsSSM:
            suggestedField("Profile", text: $connection.awsProfile, values: awsProfiles, help: "Profiles from ~/.aws/config")
            TextField("Region", text: $connection.awsRegion)
            JumpHostField(text: $connection.awsTarget, instances: awsInventory.instances)
            HStack(spacing: 8) {
                Button("Refresh AWS resources") { Task { await discoverAWS(refresh: true) } }
                    .disabled(discovering || isBreakglass)
                if discovering { ProgressView().controlSize(.small) }
                Text(isBreakglass ? "Breakglass profiles are never scanned" : awsInventory == AWSInventory() ? "" : awsInventory.summary)
                    .font(.caption)
                    .foregroundStyle(awsInventory.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
        }
    }

    private func suggestedField(_ title: String, text: Binding<String>, prompt: String? = nil, values: [String], help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: text, prompt: prompt.map(Text.init))
                    .labelsHidden()
                suggestions(values, into: text, help: help)
            }
        }
    }

    @ViewBuilder
    private func suggestions(_ values: [String], into binding: Binding<String>, help: String) -> some View {
        if !values.isEmpty {
            Menu {
                ForEach(values, id: \.self) { value in
                    Button(value) { binding.wrappedValue = value }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
        }
    }

    private var footnote: String {
        switch connection.kind {
        case .ssh:
            "Forwards bind to 127.0.0.1 on this Mac. The remote host is resolved from the SSH server, so \"localhost\" means the server itself. Remote forwards open a port on the server that reaches a host from this Mac; SOCKS forwards expose a proxy on the local port."
        case .kubernetes:
            "Each forward runs kubectl port-forward. Resource is a service, deployment, or pod such as svc/web, and the remote port is the port on that resource."
        case .awsSSM:
            "Host, RDS and MSK forwards run an SSM port-forwarding session through the jump host and need the Session Manager plugin. The jump host is an instance id, or a Name tag pattern resolved to an online instance on each connect; leave it empty for any online instance. Airflow forwards need no SSM: opening the local port signs in with this profile and sends the browser to the Airflow hostname."
        }
    }
}
