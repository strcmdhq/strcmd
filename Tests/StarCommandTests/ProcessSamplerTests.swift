import Darwin
import XCTest
@testable import StarCommand

final class ProcessSamplerTests: XCTestCase {
    private let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)

    func testCPUPercentFromMachTicks() {
        let percent = ProcessSampler.cpuPercent(previousTicks: 0, currentTicks: 24_000_000, wallNanos: 2_000_000_000, timebase: timebase)
        XCTAssertEqual(percent, 50, accuracy: 0.001)
    }

    func testTwoBusyThreadsReadTwoHundred() {
        let percent = ProcessSampler.cpuPercent(previousTicks: 24_000_000, currentTicks: 72_000_000, wallNanos: 1_000_000_000, timebase: timebase)
        XCTAssertEqual(percent, 200, accuracy: 0.001)
    }

    func testNoPreviousOrZeroWallIsZero() {
        XCTAssertEqual(ProcessSampler.cpuPercent(previousTicks: nil, currentTicks: 24_000_000, wallNanos: 1_000_000_000, timebase: timebase), 0)
        XCTAssertEqual(ProcessSampler.cpuPercent(previousTicks: 0, currentTicks: 24_000_000, wallNanos: 0, timebase: timebase), 0)
    }

    func testHostBusyPercent() {
        var previous = host_cpu_load_info()
        previous.cpu_ticks = (100, 100, 100, 100)
        var current = host_cpu_load_info()
        current.cpu_ticks = (150, 125, 125, 100)
        XCTAssertEqual(ProcessSampler.busyPercent(previous: previous, current: current), 75, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.busyPercent(previous: nil, current: current), 0)
        XCTAssertEqual(ProcessSampler.busyPercent(previous: current, current: current), 0)
    }

    func testHostBusyPercentSurvivesTickWrap() {
        var previous = host_cpu_load_info()
        previous.cpu_ticks = (natural_t.max - 10, 100, natural_t.max - 20, 100)
        var current = host_cpu_load_info()
        current.cpu_ticks = (39, 125, 79, 125)
        XCTAssertEqual(ProcessSampler.busyPercent(previous: previous, current: current), 50, accuracy: 0.001)
    }

    func testDiskRateFromByteDeltas() {
        XCTAssertEqual(ProcessSampler.bytesPerSecond(previous: 1_000_000, current: 3_400_000, wallNanos: 2_000_000_000), 1_200_000)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(previous: nil, current: 3_400_000, wallNanos: 2_000_000_000), 0)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(previous: 5, current: 3, wallNanos: 2_000_000_000), 0)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(previous: 0, current: 100, wallNanos: 0), 0)
    }

    func testRateAndPortFormatting() {
        XCTAssertEqual(ProcessMonitor.rate(0), "—")
        XCTAssertTrue(ProcessMonitor.rate(1_200_000).hasSuffix("MB/s"), ProcessMonitor.rate(1_200_000))
        XCTAssertEqual(ProcessMonitor.portList([8080, 3000, 3000, 443]), "443, 3000, 8080")
        XCTAssertEqual(ProcessMonitor.portList([]), "")
    }

    func testListenerMapKeepsLowestPidPerPort() {
        let samples = [
            ProcessSample(pid: 300, name: "node", ports: [3000, 9229]),
            ProcessSample(pid: 42, name: "python3", ports: [3000]),
        ]
        let map = ProcessSampler.listeners(in: samples)
        XCTAssertEqual(map[3000], PortListener(pid: 42, name: "python3"))
        XCTAssertEqual(map[9229], PortListener(pid: 300, name: "node"))
        XCTAssertNil(map[80])
    }

    func testPortConflictMatching() {
        XCTAssertTrue(PortConflict.matches("3000: Address already in use"))
        XCTAssertTrue(PortConflict.matches("bind: address in use"))
        XCTAssertFalse(PortConflict.matches("Connection refused"))
        XCTAssertFalse(PortConflict.matches(nil))
    }

    func testLiveSampleListsOwnProcess() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(socket, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socket, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)

        var sampler = ProcessSampler()
        _ = sampler.sample()
        let (system, processes) = sampler.sample()
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        XCTAssertTrue(me.ports.contains(port), "expected \(port) in \(me.ports)")
        XCTAssertTrue(me.sockets.contains(ListeningSocket(port: port, address: "127.0.0.1")), "\(me.sockets)")
        XCTAssertFalse(me.arguments.isEmpty)
        XCTAssertNotNil(me.startTime)
        XCTAssertGreaterThan(me.threadCount, 0)
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertFalse(me.path.isEmpty)
        XCTAssertGreaterThan(system.memoryTotal, 0)
        XCTAssertEqual(system.loadAverages.count, 3)
        XCTAssertEqual(ProcessSampler.scanListeners()[port]?.pid, getpid())
    }
}
