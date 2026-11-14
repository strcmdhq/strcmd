import SwiftUI
import XCTest
@testable import StarCommand

@MainActor
final class MenuRenderTests: XCTestCase {
    func testDisconnectedConnectionIsListed() throws {
        let store = ConfigStore(directory: scratchDirectory())
        var connection = Connection()
        connection.name = "Studio"
        connection.destination = "innerspeaker.io"
        connection.forwards = [
            PortForward(label: "Frontend", localPort: 3000, remotePort: 3000, enabled: false),
            PortForward(label: "Backend", localPort: 3100, remotePort: 3100, enabled: false),
        ]
        store.connections = [connection]
        let settings = AppSettings()
        let manager = ConnectionManager(store: store, settings: settings)
        let awake = AwakeController(settings: settings, wantedConnections: manager.$hasWantedConnections)

        let renderer = ImageRenderer(content: MenuView().environmentObject(settings).environmentObject(store).environmentObject(manager).environmentObject(awake).environmentObject(HotKeyController(settings: settings)).environmentObject(QuickTools(settings: settings)).environmentObject(LogStore()).environmentObject(ProcessMonitor()))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let out = ProcessInfo.processInfo.environment["RENDER_OUT"] {
            let png = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertGreaterThan(image.size.height, 200, "panel should be tall enough to show the connection and its forwards")
    }

    func testClaudeLineRendersWithSyntheticSessions() throws {
        let settings = AppSettings()
        let old = Date().addingTimeInterval(-30 * 86_400)
        let snapshot = ClaudeSnapshot(
            sessions: (1...16).map { ClaudeSession(pid: Int32(1000 + $0), cwd: "/work/user-interface-and-apis", startTime: old) },
            totalMemoryBytes: 6_400_000_000,
            swap: SwapUsage(total: 100, used: 93)
        )
        let insights = ClaudeInsights(snapshot: snapshot, staleDays: settings.claudeStaleDays, now: Date())
        XCTAssertTrue(insights.menuText.hasPrefix("Claude: 16 sessions · "), insights.menuText)
        XCTAssertTrue(insights.warning)

        let line = try XCTUnwrap(render(ClaudeMenuLine().environmentObject(ProcessMonitor(claude: snapshot)).environmentObject(settings).frame(width: 336)))
        XCTAssertGreaterThan(line.size.height, 0)
        let withSessions = try XCTUnwrap(render(menu(settings: settings, monitor: ProcessMonitor(claude: snapshot))))
        let without = try XCTUnwrap(render(menu(settings: settings, monitor: ProcessMonitor())))
        XCTAssertGreaterThan(withSessions.size.height, without.size.height, "the Claude line should take space only when sessions exist")
    }

    private func menu(settings: AppSettings, monitor: ProcessMonitor) -> some View {
        let store = ConfigStore(directory: scratchDirectory())
        store.connections = []
        let manager = ConnectionManager(store: store, settings: settings)
        let awake = AwakeController(settings: settings, wantedConnections: manager.$hasWantedConnections)
        return MenuView().environmentObject(settings).environmentObject(store).environmentObject(manager).environmentObject(awake)
            .environmentObject(HotKeyController(settings: settings)).environmentObject(QuickTools(settings: settings)).environmentObject(LogStore()).environmentObject(monitor)
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StarCommandTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }
}
