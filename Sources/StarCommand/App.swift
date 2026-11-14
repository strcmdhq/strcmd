import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct StarCommandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings: AppSettings
    @StateObject private var store: ConfigStore
    @StateObject private var log: LogStore
    @StateObject private var manager: ConnectionManager
    @StateObject private var awake: AwakeController
    @StateObject private var hotKey: HotKeyController
    @StateObject private var tools: QuickTools
    @StateObject private var monitor = ProcessMonitor()

    init() {
        let settings = AppSettings()
        let store = ConfigStore()
        let log = LogStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        _log = StateObject(wrappedValue: log)
        let manager = ConnectionManager(store: store, settings: settings, log: log)
        _manager = StateObject(wrappedValue: manager)
        _awake = StateObject(wrappedValue: AwakeController(settings: settings, wantedConnections: manager.$hasWantedConnections))
        _hotKey = StateObject(wrappedValue: HotKeyController(settings: settings))
        _tools = StateObject(wrappedValue: QuickTools(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(awake)
                .environmentObject(hotKey)
                .environmentObject(tools)
                .environmentObject(log)
                .environmentObject(monitor)
        } label: {
            Image(nsImage: MenuGlyph.image(for: manager.menuState))
        }
        .menuBarExtraStyle(.window)

        Window("Star Command Connections", id: "editor") {
            EditorView()
                .frame(minWidth: 880, minHeight: 600)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(log)
        }
        .defaultSize(width: 1040, height: 720)

        Window("Star Command Log", id: "log") {
            LogView()
                .environmentObject(store)
                .environmentObject(log)
        }
        .defaultSize(width: 720, height: 420)

        Window("Processes", id: "processes") {
            ProcessesView()
                .environmentObject(monitor)
        }
        .defaultSize(width: 860, height: 480)

        Window("Claude Sessions", id: "claude-sessions") {
            ClaudeSessionsView()
                .environmentObject(monitor)
                .environmentObject(settings)
        }
        .defaultSize(width: 1000, height: 560)
    }
}
