import AppKit
import Combine
import IOKit.pwr_mgt

enum AwakeMode: String, CaseIterable, Identifiable {
    case systemOnly, systemAndDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemOnly: "Mac only"
        case .systemAndDisplay: "Mac and display"
        }
    }

    var caption: String {
        switch self {
        case .systemOnly: "display may sleep"
        case .systemAndDisplay: "display stays on"
        }
    }

    fileprivate var assertionTypes: [String] {
        switch self {
        case .systemOnly: [kIOPMAssertionTypePreventUserIdleSystemSleep]
        case .systemAndDisplay: [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep]
        }
    }
}

enum AwakeDuration: CaseIterable, Identifiable {
    case untilOff, oneHour, fourHours, eightHours

    var id: Self { self }

    var seconds: TimeInterval? {
        switch self {
        case .untilOff: nil
        case .oneHour: 3600
        case .fourHours: 4 * 3600
        case .eightHours: 8 * 3600
        }
    }

    var title: String {
        switch self {
        case .untilOff: "Until turned off"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .eightHours: "8 hours"
        }
    }
}

@MainActor
final class AwakeController: ObservableObject {
    enum Reason: Equatable { case manual, connections }

    @Published private(set) var isActive = false
    @Published private(set) var mode: AwakeMode = .systemOnly
    @Published private(set) var expiresAt: Date?
    @Published private(set) var reason: Reason?
    @Published var manualMode: AwakeMode = .systemOnly {
        didSet {
            guard let current = manual else { return }
            manual = (manualMode, current.expiresAt)
            apply()
        }
    }
    @Published var manualDuration: AwakeDuration = .untilOff {
        didSet { if isManual { enable(mode: manualMode, for: manualDuration.seconds) } }
    }

    private let assertions = PowerAssertions()
    private var manual: (mode: AwakeMode, expiresAt: Date?)?
    private var hasWantedConnections = false
    private var keepAwakeWhileConnected = false
    private var keepAwakeMode: AwakeMode = .systemOnly
    private var expiryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, wantedConnections: some Publisher<Bool, Never>) {
        wantedConnections
            .removeDuplicates()
            .sink { [weak self] wanted in
                self?.hasWantedConnections = wanted
                self?.apply()
            }
            .store(in: &cancellables)
        settings.$keepAwakeWhileConnected
            .combineLatest(settings.$keepAwakeMode)
            .sink { [weak self] enabled, mode in
                self?.keepAwakeWhileConnected = enabled
                self?.keepAwakeMode = mode
                self?.apply()
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.assertions.release() }
        }
    }

    var isManual: Bool { manual != nil }

    var statusText: String? {
        guard isActive, let reason else { return nil }
        return Self.caption(mode: mode, reason: reason, expiresAt: expiresAt)
    }

    static func caption(mode: AwakeMode, reason: Reason, expiresAt: Date?) -> String {
        switch reason {
        case .connections:
            return "Awake while connections are active"
        case .manual:
            var parts = ["Awake", mode.caption]
            if let expiresAt { parts.append("until " + expiresAt.formatted(date: .omitted, time: .shortened)) }
            return parts.joined(separator: " · ")
        }
    }

    func enable(mode: AwakeMode, for duration: TimeInterval?) {
        expiryTask?.cancel()
        let expiresAt = duration.map { Date().addingTimeInterval($0) }
        manual = (mode, expiresAt)
        if let duration {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.disable()
            }
        }
        apply()
    }

    func disable() {
        expiryTask?.cancel()
        expiryTask = nil
        manual = nil
        apply()
    }

    private func apply() {
        if let manual {
            assertions.hold(manual.mode)
            (isActive, mode, reason, expiresAt) = (true, manual.mode, .manual, manual.expiresAt)
        } else if keepAwakeWhileConnected, hasWantedConnections {
            assertions.hold(keepAwakeMode)
            (isActive, mode, reason, expiresAt) = (true, keepAwakeMode, .connections, nil)
        } else {
            assertions.release()
            (isActive, reason, expiresAt) = (false, nil, nil)
        }
    }
}

private final class PowerAssertions {
    private var ids: [IOPMAssertionID] = []
    private var mode: AwakeMode?

    func hold(_ newMode: AwakeMode) {
        guard newMode != mode else { return }
        release()
        mode = newMode
        for type in newMode.assertionTypes {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Star Command stay awake" as CFString, &id)
            if status == kIOReturnSuccess { ids.append(id) }
        }
    }

    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
        mode = nil
    }

    deinit { release() }
}
