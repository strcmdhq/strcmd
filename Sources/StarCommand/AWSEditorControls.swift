import SwiftUI

struct AWSServicePicker: View {
    @Binding var forward: PortForward

    var body: some View {
        Picker("Service", selection: Binding(get: { forward.awsService }, set: { forward.selectService($0) })) {
            ForEach(AWSService.allCases) { service in
                Label(service.title, systemImage: service.symbol).tag(service)
            }
        }
        .pickerStyle(.menu)
    }
}

struct AWSResourceField: View {
    @Binding var forward: PortForward
    let inventory: AWSInventory

    var body: some View {
        HStack(spacing: 4) {
            switch forward.awsService {
            case .host:
                TextField("Host", text: $forward.remoteHost, prompt: Text(ConnectionKind.awsSSM.remoteFieldPrompt))
            case .rds:
                TextField("Database", text: $forward.awsResource, prompt: Text("DB instance identifier"))
                menu(help: "RDS databases", empty: inventory.databases.isEmpty) {
                    ForEach(inventory.databases) { database in
                        Button("\(database.identifier) · \(database.engine)") { choose(database.identifier, port: database.port) }
                    }
                }
            case .msk:
                TextField("Broker", text: $forward.remoteHost, prompt: Text("broker hostname"))
                    .help(forward.awsResource.isEmpty ? "Kafka broker hostname" : "Broker of \(forward.awsResource)")
                menu(help: "Kafka brokers", empty: inventory.clusters.allSatisfy(\.brokers.isEmpty)) {
                    ForEach(inventory.clusters) { cluster in
                        Section(cluster.name) {
                            ForEach(cluster.brokers, id: \.host) { broker in
                                Button(broker.host) {
                                    forward.remoteHost = broker.host
                                    choose(cluster.name, port: broker.port)
                                }
                            }
                        }
                    }
                }
            case .mwaa:
                TextField("Environment", text: $forward.awsResource, prompt: Text("MWAA environment name"))
                menu(help: "Airflow environments", empty: inventory.airflows.isEmpty) {
                    ForEach(inventory.airflows, id: \.self) { name in
                        Button(name) { choose(name, port: nil) }
                    }
                }
            }
        }
    }

    private func choose(_ resource: String, port: Int?) {
        forward.awsResource = resource
        if let port { forward.remotePort = port }
        if forward.label.isEmpty { forward.label = resource }
    }

    @ViewBuilder
    private func menu(help: String, empty: Bool, @ViewBuilder content: () -> some View) -> some View {
        if !empty {
            Menu(content: content) { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(help)
        }
    }
}

struct JumpHostField: View {
    @Binding var text: String
    let instances: [AWSInstance]

    private var names: [String] {
        var seen = Set<String>()
        return instances.map(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    var body: some View {
        LabeledContent("Jump host") {
            HStack(spacing: 6) {
                TextField("Jump host", text: $text, prompt: Text("\(JumpHost.defaultPattern), a Name tag pattern, or i-0123…"))
                    .labelsHidden()
                Menu {
                    Section("Resolve on connect") {
                        Button("\(JumpHost.defaultPattern) (default)") { text = JumpHost.defaultPattern }
                        ForEach(names, id: \.self) { name in
                            Button(name) { text = name }
                        }
                        Button("Any online instance") { text = "" }
                    }
                    if !instances.isEmpty {
                        Section("Fixed instance") {
                            ForEach(instances) { instance in
                                Button(instance.name.isEmpty ? instance.id : "\(instance.name) · \(instance.id)") { text = instance.id }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("SSM-online instances in this profile and region")
            }
        }
    }
}
