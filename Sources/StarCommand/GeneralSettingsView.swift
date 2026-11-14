import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
                    .disabled(!AppSettings.isBundled)
                if !AppSettings.isBundled {
                    caption("Available when running the installed Star Command.app")
                }
                if settings.launchAtLoginNeedsApproval {
                    HStack {
                        caption("Approve Star Command under Login Items")
                        Button("Open Login Items", action: settings.openLoginItemsSettings)
                    }
                }
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Shortcut") {
                Toggle("Open Star Command with ⌃⌥B", isOn: $settings.hotkeyEnabled)
                caption("The shortcut is fixed for now")
            }
            Section("Notifications") {
                Toggle("Notify when a connection drops or recovers", isOn: $settings.notificationsEnabled)
            }
            Section("Claude sessions") {
                Stepper("Stale after \(settings.claudeStaleDays) days idle", value: $settings.claudeStaleDays, in: 1...90)
                caption("Idle sessions older than this are flagged and offered for bulk close")
            }
            Section("Stay awake") {
                Toggle("Keep awake while connected", isOn: $settings.keepAwakeWhileConnected)
                caption("Hold the Mac awake while any connection is on")
                Picker("Mode", selection: $settings.keepAwakeMode) {
                    ForEach(AwakeMode.allCases) { mode in
                        Text("\(mode.title) · \(mode.caption)").tag(mode)
                    }
                }
                .disabled(!settings.keepAwakeWhileConnected)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear(perform: settings.refreshLaunchAtLogin)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
