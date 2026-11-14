import Foundation

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var lineStart = 0
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        while onLine != nil, let newline = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: data[lineStart..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lineStart = newline + 1
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = process
    }

    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = nil
    }

    func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        for process in processes.values where process.isRunning { process.terminate() }
        processes.removeAll()
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Tools {
    struct Result {
        let status: Int32
        let stderr: String
    }

    private static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }()

    // GUI apps inherit a minimal launchd environment: no Homebrew PATH and often no agent socket.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var path: [String] = []
        for entry in searchPaths + existing where !path.contains(entry) { path.append(entry) }
        env["PATH"] = path.joined(separator: ":")
        if env["SSH_AUTH_SOCK"] == nil, let socket = launchctlGetenv("SSH_AUTH_SOCK") {
            env["SSH_AUTH_SOCK"] = socket
        }
        return env
    }()

    static func find(_ name: String) -> URL? {
        for dir in environment["PATH"]!.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func require(_ name: String, hint: String? = nil) throws -> URL {
        guard let url = find(name) else {
            throw ToolError(message: hint.map { "\(name) not found. \($0)" } ?? "\(name) not found on PATH")
        }
        return url
    }

    static func commandLine(_ executable: URL, _ arguments: [String]) -> String {
        ([executable.lastPathComponent] + arguments)
            .map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    static func makeProcess(_ executable: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        return process
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval? = nil) async -> Result {
        await finish(makeProcess(executable, arguments), timeout: timeout)
    }

    struct Capture {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    static func capture(_ executable: URL, _ arguments: [String], timeout: TimeInterval? = nil) async -> Capture {
        let process = makeProcess(executable, arguments)
        let stdout = Pipe()
        process.standardOutput = stdout
        var reader: Task<Data, Never>?
        // Drain stdout while the process runs; output can exceed the pipe buffer.
        let result = await finish(process, timeout: timeout) {
            reader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        }
        return Capture(status: result.status, stdout: await reader?.value ?? Data(), stderr: result.stderr)
    }

    private static func finish(_ process: Process, timeout: TimeInterval?, onLaunch: () -> Void = {}) async -> Result {
        let stderr = Pipe()
        process.standardError = stderr
        let watchdog: Task<Void, Never>? = timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if process.isRunning { process.terminate() }
            }
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                watchdog?.cancel()
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: Result(status: finished.terminationStatus, stderr: text))
            }
            do {
                try process.run()
                onLaunch()
            } catch {
                continuation.resume(returning: Result(status: -1, stderr: error.localizedDescription))
            }
        }
    }

    static func captureStderr(of process: Process, into buffer: OutputBuffer) {
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { buffer.append(chunk) }
        }
    }

    static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    static func firstLine(_ text: String) -> String? {
        lines(text).first
    }

    static func lastLine(_ text: String) -> String? {
        lines(text).last
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func launchctlGetenv(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
