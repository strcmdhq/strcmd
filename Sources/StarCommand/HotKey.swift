import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class HotKeyController: ObservableObject {
    var openWindow: ((String) -> Void)?

    private static let signature = "BRTH".utf8.reduce(OSType(0)) { $0 << 8 | OSType($1) }
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .first()
            .flatMap { _ in settings.$hotkeyEnabled }
            .sink { [weak self] enabled in
                if enabled { self?.register() } else { self?.unregister() }
            }
            .store(in: &cancellables)
    }

    private static let callback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated {
            Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue().togglePanel()
        }
        return noErr
    }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    // SwiftUI offers no API to open a window-style MenuBarExtra, so click its status item.
    func togglePanel() {
        let statusButton = NSApp.windows
            .first { $0.className == "NSStatusBarWindow" }?
            .contentView?.subviews
            .compactMap { $0 as? NSStatusBarButton }
            .first
        if let statusButton {
            statusButton.performClick(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openWindow?("editor")
        }
    }
}
