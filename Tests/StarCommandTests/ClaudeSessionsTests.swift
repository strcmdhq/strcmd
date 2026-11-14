import Darwin
import XCTest
@testable import StarCommand

final class ClaudeSessionsTests: XCTestCase {
    private let cli = "/Users/me/.local/share/claude/versions/2.1.283"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClassificationFromArgv() {
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude"], executablePath: cli), .session)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["/Users/me/.local/bin/claude", "--resume"], executablePath: cli), .session)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude", "fix the flaky test"], executablePath: cli), .session)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/cc-daemon-501/a/spare/b.pty.sock", "200", "50", "--"], executablePath: cli), .helper)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude", "bg-spare", "--bg-spare", "/tmp/cc-daemon-501/a/spare/b.claim.sock"], executablePath: cli), .helper)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/a/spare/b.pty.sock 200 50 --"], executablePath: cli), .helper)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["claude bg-spare --bg-spare /tmp/cc-daemon-501/a/spare/b.claim.sock", "", "200"], executablePath: cli), .helper)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["/Users/me/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", "--bg-pty-host", "/tmp/x.sock"], executablePath: cli), .helper)
        XCTAssertEqual(ClaudeSessionRules.classify(arguments: ["/Users/me/.local/bin/claude", "daemon", "run"], executablePath: cli), .helper)
        XCTAssertNil(ClaudeSessionRules.classify(arguments: ["claude", "mcp", "serve"], executablePath: cli))
        XCTAssertNil(ClaudeSessionRules.classify(arguments: ["claude", "doctor"], executablePath: cli))
        XCTAssertNil(ClaudeSessionRules.classify(arguments: ["/Applications/_claude.app/Contents/MacOS/Claude"], executablePath: "/Applications/_claude.app/Contents/MacOS/Claude"))
        XCTAssertNil(ClaudeSessionRules.classify(arguments: ["claude"], executablePath: "/Applications/_claude.app/Contents/Helpers/claude"))
        XCTAssertNil(ClaudeSessionRules.classify(arguments: ["node", "server.js"], executablePath: "/opt/homebrew/bin/node"))
        XCTAssertNil(ClaudeSessionRules.classify(arguments: [], executablePath: cli))
    }

    func testDevServerNames() {
        XCTAssertEqual(ClaudeSessionRules.devServerName(arguments: ["node", "vite"], executablePath: "/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(ClaudeSessionRules.devServerName(arguments: ["/usr/local/bin/python3.12", "-m", "http.server"], executablePath: "/x/Python"), "python3.12")
        XCTAssertEqual(ClaudeSessionRules.devServerName(arguments: ["next-server (v15)"], executablePath: "/opt/homebrew/bin/node"), "node")
        XCTAssertNil(ClaudeSessionRules.devServerName(arguments: ["/bin/zsh", "-c", "yarn dev"], executablePath: "/bin/zsh"))
    }

    func testProjectsFolderEncoding() {
        XCTAssertEqual(ClaudeSessionRules.projectsFolderName(for: "/Users/dev/Development/gitlab.com/user-interface-and-apis"),
                       "-Users-dev-Development-gitlab-com-user-interface-and-apis")
        XCTAssertEqual(ClaudeSessionRules.projectsFolderName(for: "/private/tmp/claude-501/-Users-x"), "-private-tmp-claude-501--Users-x")
    }

    func testParsesProcArgs2Buffer() throws {
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/Users/me/.local/share/claude/versions/2.1.283".utf8) + [0, 0, 0, 0]
        for argument in ["claude", "bg-spare", "--bg-spare"] { buffer += Array(argument.utf8) + [0] }
        buffer += Array("HOME=/Users/me".utf8) + [0]
        let parsed = try XCTUnwrap(ProcArgs.parse(buffer))
        XCTAssertEqual(parsed.path, "/Users/me/.local/share/claude/versions/2.1.283")
        XCTAssertEqual(parsed.arguments, ["claude", "bg-spare", "--bg-spare"])
        XCTAssertNil(ProcArgs.parse([1, 0]))
        XCTAssertEqual(ProcArgs.parse(withUnsafeBytes(of: Int32(2)) { Array($0) } + Array("/bin/x".utf8) + [0] + Array("x".utf8))?.arguments, [])
    }

    func testSwapParsing() {
        var usage = xsw_usage()
        usage.xsu_total = 23_552 << 20
        usage.xsu_used = 21_892 << 20
        let swap = SwapUsage(usage)
        XCTAssertEqual(swap.fraction, 0.9295, accuracy: 0.001)
        XCTAssertTrue(swap.isHigh)
        XCTAssertFalse(SwapUsage(total: 0, used: 0).isHigh)
        XCTAssertFalse(SwapUsage(total: 100, used: 80).isHigh)
    }

    func testSubtreeAggregationStopsAtNestedSessions() throws {
        let processes = [
            sample(10, parent: 1, memory: 100, cpu: 1, arguments: ["claude"], path: cli),
            sample(11, parent: 10, memory: 20, cpu: 2, arguments: ["/bin/zsh", "-c", "yarn dev"], path: "/bin/zsh"),
            sample(14, parent: 11, memory: 10, arguments: ["node", "/opt/homebrew/bin/yarn", "dev"], path: "/opt/homebrew/bin/node"),
            sample(15, parent: 10, memory: 40, arguments: ["python", "-m", "mcp_server"], path: "/x/Python"),
            sample(12, parent: 14, memory: 300, cpu: 30, arguments: ["node", "vite"], path: "/opt/homebrew/bin/node", sockets: [ListeningSocket(port: 5173, address: "::")]),
            sample(13, parent: 12, memory: 5, arguments: ["esbuild"], path: "/x/esbuild"),
            sample(20, parent: 10, memory: 50, arguments: ["claude"], path: cli),
            sample(21, parent: 20, memory: 7, arguments: ["node", "x"], path: "/opt/homebrew/bin/node", sockets: [ListeningSocket(port: 3000, address: "127.0.0.1")]),
            sample(30, parent: 1, memory: 9, arguments: ["claude", "bg-pty-host"], path: cli),
            sample(31, parent: 30, memory: 4, arguments: ["claude", "bg-spare"], path: cli),
            sample(40, parent: 1, memory: 1000, arguments: ["/Applications/_claude.app/Contents/MacOS/Claude"], path: "/Applications/_claude.app/Contents/MacOS/Claude", sockets: [ListeningSocket(port: 7000, address: "0.0.0.0")]),
        ]
        var sampler = ClaudeSessionSampler(projectsRoot: URL(fileURLWithPath: "/nonexistent-strcmd-tests"), currentDirectory: { "/work/app\($0)" }, swapUsage: { SwapUsage(total: 10, used: 9) })
        let snapshot = sampler.update(processes, now: now)

        XCTAssertEqual(snapshot.sessions.map(\.pid).sorted(), [10, 20])
        XCTAssertEqual(snapshot.helpers.map(\.pid), [30, 31])
        let parent = try XCTUnwrap(snapshot.sessions.first { $0.pid == 10 })
        XCTAssertEqual(parent.treeMemoryBytes, 475)
        XCTAssertEqual(parent.treeCPUPercent, 33, accuracy: 0.001)
        XCTAssertEqual(parent.descendantCount, 5)
        XCTAssertEqual(parent.devServers.map(\.pid), [12, 14])
        XCTAssertEqual(parent.devServers.first?.ports, [5173])
        XCTAssertEqual(parent.cwd, "/work/app10")
        XCTAssertNil(parent.lastActivity)
        XCTAssertEqual(snapshot.sessions.first { $0.pid == 20 }?.treeMemoryBytes, 57)
        XCTAssertEqual(snapshot.totalMemoryBytes, 532)
        XCTAssertEqual(snapshot.wildcardListeners.map(\.pid), [12, 40])
        XCTAssertEqual(snapshot.wildcardListeners.first?.sessionPID, 10)
        XCTAssertNil(snapshot.wildcardListeners.last?.sessionPID)
        XCTAssertEqual(snapshot.swap?.isHigh, true)
    }

    func testLastActivityFromTranscriptsWithRealpathFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strcmd-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/project")
        let link = root.appendingPathComponent("link")
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let folder = projects.appendingPathComponent(ClaudeSessionRules.projectsFolderName(for: real.resolvingSymlinksInPath().path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let newest = now.addingTimeInterval(-60)
        for (name, date) in [("a.jsonl", now.addingTimeInterval(-86_400)), ("b.jsonl", newest), ("c.txt", now)] {
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }

        let sampler = ClaudeSessionSampler(projectsRoot: projects, currentDirectory: { _ in nil }, swapUsage: { nil })
        let found = try XCTUnwrap(sampler.transcriptFolder(cwd: link.appendingPathComponent("project").path))
        XCTAssertEqual(found.lastPathComponent, folder.lastPathComponent)
        XCTAssertEqual(try XCTUnwrap(ClaudeSessionSampler.newestTranscript(in: found)).timeIntervalSince1970, newest.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(sampler.transcriptFolder(cwd: "/no/such/place"))
        XCTAssertNil(sampler.transcriptFolder(cwd: ""))
    }

    func testStaleFilterSkipsActiveAndHelpers() {
        let days = 7
        let old = now.addingTimeInterval(-10 * 86_400)
        let idle = ClaudeSession(pid: 1, cwd: "/a", startTime: old, lastActivity: now.addingTimeInterval(-8 * 86_400))
        let active = ClaudeSession(pid: 2, cwd: "/a", startTime: old, lastActivity: now.addingTimeInterval(-60))
        let recent = ClaudeSession(pid: 3, cwd: "/b", startTime: old, lastActivity: now.addingTimeInterval(-86_400))
        let unknown = ClaudeSession(pid: 4, cwd: "/c", startTime: old)
        let helper = ClaudeSession(pid: 5, role: .helper, startTime: old)
        let insights = ClaudeInsights(snapshot: ClaudeSnapshot(sessions: [idle, active, recent, unknown], helpers: [helper]), staleDays: days, now: now)
        XCTAssertEqual(insights.stale.map(\.pid), [1, 4])
        XCTAssertFalse(ClaudeSessionRules.isStale(helper, days: days, now: now))
        XCTAssertEqual(insights.olderCount, 4)
        XCTAssertEqual(insights.activeCount, 1)
        XCTAssertTrue(insights.warning)
        XCTAssertEqual(insights.crowds.map(\.text), ["2 sessions in a"])
    }

    func testMenuTextAndFormatting() {
        let snapshot = ClaudeSnapshot(sessions: [ClaudeSession(pid: 1)], totalMemoryBytes: 6_400_000_000)
        let insights = ClaudeInsights(snapshot: snapshot, staleDays: 7, now: now)
        XCTAssertTrue(insights.menuText.hasPrefix("Claude: 1 session · "), insights.menuText)
        XCTAssertFalse(insights.warning)
        XCTAssertEqual(ClaudeFormat.duration(59), "0m")
        XCTAssertEqual(ClaudeFormat.duration(3_700), "1h 1m")
        XCTAssertEqual(ClaudeFormat.duration(90_000), "1d 1h")
        XCTAssertEqual(ClaudeFormat.path("/Users/me/code/x", home: "/Users/me"), "~/code/x")
        XCTAssertEqual(ClaudeFormat.path("/Users/meow", home: "/Users/me"), "/Users/meow")
        XCTAssertEqual(ClaudeFormat.path("", home: "/Users/me"), "unknown")
    }

    func testWildcardAddresses() {
        XCTAssertTrue(ListeningSocket(port: 1, address: "0.0.0.0").isWildcard)
        XCTAssertTrue(ListeningSocket(port: 1, address: "::").isWildcard)
        XCTAssertFalse(ListeningSocket(port: 1, address: "127.0.0.1").isWildcard)
        XCTAssertFalse(ListeningSocket(port: 1, address: "::1").isWildcard)
    }

    func testSignalRefusalsWithoutSignalling() {
        let mine = ProcInfo.Identity(uid: 501, parentPID: 1, startTime: now)
        let theirs = ProcInfo.Identity(uid: 0, parentPID: 1, startTime: now)
        XCTAssertNil(ProcessMonitor.refusal(pid: 500, identity: mine, ownPID: 100, ownUID: 501, ancestors: [50]))
        XCTAssertNotNil(ProcessMonitor.refusal(pid: 500, identity: theirs, ownPID: 100, ownUID: 501, ancestors: [50]))
        XCTAssertNotNil(ProcessMonitor.refusal(pid: 100, identity: mine, ownPID: 100, ownUID: 501, ancestors: [50]))
        XCTAssertNotNil(ProcessMonitor.refusal(pid: 50, identity: mine, ownPID: 100, ownUID: 501, ancestors: [50]))
        XCTAssertNotNil(ProcessMonitor.refusal(pid: 500, identity: nil, ownPID: 100, ownUID: 501, ancestors: []))
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertNotNil(ProcessMonitor.refusal(pid: pid, identity: mine, ownPID: 100, ownUID: 501, ancestors: []))
        }
    }

    func testOwnAncestorsAndIdentityAreReadable() throws {
        let me = try XCTUnwrap(ProcInfo.identity(pid: getpid()))
        XCTAssertEqual(me.uid, getuid())
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertTrue(ProcInfo.ancestors(of: getpid()).contains(getppid()))
        XCTAssertNotNil(ProcInfo.currentDirectory(pid: getpid()))
        XCTAssertFalse(ProcessMonitor.isSameProcess(pid: getpid(), startTime: me.startTime?.addingTimeInterval(1)))
        XCTAssertTrue(ProcessMonitor.isSameProcess(pid: getpid(), startTime: me.startTime))
    }

    func testLiveSessionsReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BERTH_LIVE_CLAUDE"] == "1", "set BERTH_LIVE_CLAUDE=1 to list sessions on this Mac")
        var processes = ProcessSampler()
        var sessions = ClaudeSessionSampler()
        _ = processes.sample()
        let snapshot = sessions.update(processes.sample().1)
        let insights = ClaudeInsights(snapshot: snapshot, staleDays: 7, now: Date())
        print("LIVE sessions=\(snapshot.sessions.count) helpers=\(snapshot.helpers.count) total=\(ClaudeFormat.memory(snapshot.totalMemoryBytes)) active=\(insights.activeCount) stale=\(insights.stale.count) older=\(insights.olderCount)")
        print("LIVE \(insights.swapText ?? "no swap") crowds=\(insights.crowds.map(\.text))")
        for helper in snapshot.helpers {
            print("LIVE helper \(helper.pid) tree=\(ClaudeFormat.memory(helper.treeMemoryBytes))")
        }
        for session in snapshot.sessions {
            print("LIVE session \(session.pid) \(ClaudeFormat.path(session.cwd)) age=\(ClaudeFormat.duration(session.age(at: Date()))) tree=\(ClaudeFormat.memory(session.treeMemoryBytes)) activity=\(ClaudeFormat.activity(session, now: Date())) dev=\(session.devServerText)")
        }
        for listener in snapshot.wildcardListeners {
            print("LIVE wildcard \(listener.name) \(listener.pid) \(listener.socket.address):\(listener.socket.port) session=\(listener.sessionPID.map(String.init) ?? "-")")
        }
    }

    private func sample(_ pid: Int32, parent: Int32, memory: UInt64, cpu: Double = 0, arguments: [String], path: String, sockets: [ListeningSocket] = []) -> ProcessSample {
        ProcessSample(pid: pid, name: URL(fileURLWithPath: path).lastPathComponent, path: path, parentPID: parent, cpuPercent: cpu, memoryBytes: memory,
                      ports: ProcessSampler.ports(sockets), sockets: sockets, startTime: now.addingTimeInterval(-3_600), arguments: arguments)
    }
}
