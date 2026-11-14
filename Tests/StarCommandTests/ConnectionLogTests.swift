import XCTest
@testable import StarCommand

@MainActor
final class ConnectionLogTests: XCTestCase {
    func testRingBufferKeepsNewest() {
        let log = LogStore()
        let id = UUID()
        for i in 0..<600 { log.append(id, .info, "line \(i)") }
        let entries = log.entries[id] ?? []
        XCTAssertEqual(entries.count, LogStore.capacity)
        XCTAssertEqual(entries.first?.text, "line 100")
        XCTAssertEqual(entries.last?.text, "line 599")
    }

    func testTextJoinsTimestampedLines() {
        let log = LogStore()
        let id = UUID()
        log.append(id, .info, "a")
        log.append(id, .error, "b")
        let lines = log.text(id).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("  a"))
        XCTAssertTrue(lines[1].hasSuffix("  b"))
        log.clear(id)
        XCTAssertEqual(log.text(id), "")
    }

    func testOutputBufferEmitsCompleteLines() {
        let lock = NSLock()
        var lines: [String] = []
        let buffer = OutputBuffer { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        buffer.append(Data("first\nsec".utf8))
        buffer.append(Data("ond\r\n\n  third \n".utf8))
        buffer.append(Data("tail".utf8))
        XCTAssertEqual(lines, ["first", "second", "third"])
        XCTAssertEqual(buffer.text, "first\nsecond\r\n\n  third \ntail")
    }

    func testCommandLineQuotesWhitespace() {
        let line = Tools.commandLine(URL(fileURLWithPath: "/usr/bin/ssh"), ["-o", "ServerAliveInterval=10", "a b"])
        XCTAssertEqual(line, "ssh -o ServerAliveInterval=10 \"a b\"")
    }
}
