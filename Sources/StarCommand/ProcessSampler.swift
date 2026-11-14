import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ size: UInt32) -> Int32

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_pidfdinfo")
private func proc_pidfdinfo(_ pid: Int32, _ fd: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

struct ProcessSampler {
    static let portScanInterval = 3
    static let maxScannedFDs = 20000
    static let keptArguments = 4

    private var previousCPU: [Int32: UInt64] = [:]
    private var previousDisk: [Int32: UInt64] = [:]
    private var paths: [Int32: String] = [:]
    private var sockets: [Int32: [ListeningSocket]] = [:]
    private var arguments: [Int32: (start: Date?, arguments: [String])] = [:]
    private var previousHost: host_cpu_load_info?
    private var previousTime: UInt64 = 0
    private var tick = 0
    private let timebase: mach_timebase_info_data_t
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let memoryTotal: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        self.pageSize = UInt64(pageSize)
        var memoryTotal: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memoryTotal, &length, nil, 0)
        self.memoryTotal = memoryTotal
    }

    mutating func sample() -> (SystemSample, [ProcessSample]) {
        let now = mach_absolute_time()
        let wallNanos = Self.nanoseconds(ticks: now &- previousTime, timebase: timebase)
        let processes = sampleProcesses(wallNanos: wallNanos)
        let hostLoad = hostCPULoad()
        let system = SystemSample(
            cpuPercent: Self.busyPercent(previous: previousHost, current: hostLoad),
            memoryUsed: memoryUsed(),
            memoryTotal: memoryTotal,
            loadAverages: loadAverages()
        )
        previousHost = hostLoad
        previousTime = now
        return (system, processes)
    }

    static func nanoseconds(ticks: UInt64, timebase: mach_timebase_info_data_t) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func cpuPercent(previousTicks: UInt64?, currentTicks: UInt64, wallNanos: UInt64, timebase: mach_timebase_info_data_t) -> Double {
        guard let previousTicks, wallNanos > 0, currentTicks >= previousTicks else { return 0 }
        let busy = nanoseconds(ticks: currentTicks - previousTicks, timebase: timebase)
        return 100 * Double(busy) / Double(wallNanos)
    }

    static func bytesPerSecond(previous: UInt64?, current: UInt64, wallNanos: UInt64) -> UInt64 {
        guard let previous, wallNanos > 0, current >= previous else { return 0 }
        return UInt64(Double(current - previous) * 1_000_000_000 / Double(wallNanos))
    }

    static func busyPercent(previous: host_cpu_load_info?, current: host_cpu_load_info) -> Double {
        guard let previous else { return 0 }
        let before = ticks(previous), after = ticks(current)
        let deltas = zip(after, before).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return 0 }
        let busy = deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_SYSTEM)] + deltas[Int(CPU_STATE_NICE)]
        return 100 * Double(busy) / Double(total)
    }

    static func listeners(in processes: [ProcessSample]) -> [UInt16: PortListener] {
        var map: [UInt16: PortListener] = [:]
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            for port in process.ports where map[port] == nil {
                map[port] = PortListener(pid: process.pid, name: process.name)
            }
        }
        return map
    }

    static func scanListeners() -> [UInt16: PortListener] {
        var found: [ProcessSample] = []
        for proc in listProcesses() where isOwn(proc) {
            let pid = proc.kp_proc.p_pid
            let sockets = listeningSockets(pid: pid)
            guard !sockets.isEmpty else { continue }
            let path = path(pid: pid)
            found.append(ProcessSample(pid: pid, name: name(path: path, proc: proc), path: path, ports: ports(sockets)))
        }
        return listeners(in: found)
    }

    private static func ticks(_ info: host_cpu_load_info) -> [natural_t] {
        withUnsafeBytes(of: info.cpu_ticks) { Array($0.bindMemory(to: natural_t.self)) }
    }

    private mutating func sampleProcesses(wallNanos: UInt64) -> [ProcessSample] {
        let all = Self.listProcesses()
        let comm = Dictionary(all.map { ($0.kp_proc.p_pid, Self.comm($0)) }, uniquingKeysWith: { first, _ in first })
        let scanPorts = tick % Self.portScanInterval == 0
        tick += 1
        var samples: [ProcessSample] = []
        var currentCPU: [Int32: UInt64] = [:]
        var currentDisk: [Int32: UInt64] = [:]
        var currentPaths: [Int32: String] = [:]
        var currentSockets: [Int32: [ListeningSocket]] = [:]
        var currentArguments: [Int32: (start: Date?, arguments: [String])] = [:]
        for proc in all where Self.isOwn(proc) {
            let pid = proc.kp_proc.p_pid
            var usage = rusage_info_v4()
            guard proc_pid_rusage(pid, RUSAGE_INFO_V4, &usage) == 0 else { continue }
            let cpuTicks = usage.ri_user_time + usage.ri_system_time
            let diskBytes = usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
            let path = paths[pid] ?? Self.path(pid: pid)
            let socketList = scanPorts ? Self.listeningSockets(pid: pid) : sockets[pid] ?? []
            let startTime = Self.startTime(proc)
            let argumentList = arguments[pid].flatMap { $0.start == startTime ? $0.arguments : nil }
                ?? Array((ProcInfo.arguments(pid: pid)?.arguments ?? []).prefix(Self.keptArguments))
            currentCPU[pid] = cpuTicks
            currentDisk[pid] = diskBytes
            currentPaths[pid] = path
            currentSockets[pid] = socketList
            currentArguments[pid] = (startTime, argumentList)
            samples.append(ProcessSample(
                pid: pid,
                name: Self.name(path: path, proc: proc),
                path: path,
                parentPID: proc.kp_eproc.e_ppid,
                parentName: comm[proc.kp_eproc.e_ppid] ?? "",
                cpuPercent: Self.cpuPercent(previousTicks: previousCPU[pid], currentTicks: cpuTicks, wallNanos: wallNanos, timebase: timebase),
                memoryBytes: usage.ri_phys_footprint,
                diskBytesPerSecond: Self.bytesPerSecond(previous: previousDisk[pid], current: diskBytes, wallNanos: wallNanos),
                threadCount: Self.threadCount(pid: pid),
                ports: Self.ports(socketList),
                paused: Int32(proc.kp_proc.p_stat) == SSTOP,
                sockets: socketList,
                startTime: startTime,
                arguments: argumentList
            ))
        }
        previousCPU = currentCPU
        previousDisk = currentDisk
        paths = currentPaths
        sockets = currentSockets
        arguments = currentArguments
        return samples.sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.name < $1.name }
    }

    static func ports(_ sockets: [ListeningSocket]) -> [UInt16] {
        Set(sockets.map(\.port)).sorted()
    }

    static func startTime(_ proc: kinfo_proc) -> Date? {
        let time = proc.kp_proc.p_un.__p_starttime
        guard time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    private static func isOwn(_ proc: kinfo_proc) -> Bool {
        proc.kp_eproc.e_ucred.cr_uid == getuid() && proc.kp_proc.p_pid > 0
    }

    private static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size / stride))
    }

    private static func path(pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
    }

    private static func name(path: String, proc: kinfo_proc) -> String {
        path.isEmpty ? comm(proc) : URL(fileURLWithPath: path).lastPathComponent
    }

    private static func comm(_ proc: kinfo_proc) -> String {
        withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func threadCount(pid: Int32) -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_threadnum) : 0
    }

    private static func listeningSockets(pid: Int32) -> [ListeningSocket] {
        let fdSize = Int32(MemoryLayout<proc_fdinfo>.stride)
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0, needed / fdSize <= maxScannedFDs else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed / fdSize) + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count) * fdSize)
        guard filled > 0 else { return [] }
        var sockets: Set<ListeningSocket> = []
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        for fd in fds.prefix(Int(filled / fdSize)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketSize) == socketSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            sockets.insert(ListeningSocket(port: port, address: localAddress(tcp.tcpsi_ini)))
        }
        return sockets.sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    private static func localAddress(_ info: in_sockinfo) -> String {
        var address = info.insi_laddr
        if info.insi_vflag & UInt8(INI_IPV4) != 0 {
            return withUnsafeBytes(of: &address.ina_46.i46a_addr4) { format(AF_INET, $0, length: INET_ADDRSTRLEN) }
        }
        return withUnsafeBytes(of: &address.ina_6) { format(AF_INET6, $0, length: INET6_ADDRSTRLEN) }
    }

    private static func format(_ family: Int32, _ bytes: UnsafeRawBufferPointer, length: Int32) -> String {
        var text = [CChar](repeating: 0, count: Int(length))
        return inet_ntop(family, bytes.baseAddress, &text, socklen_t(length)) == nil ? "" : String(cString: text)
    }

    private func hostCPULoad() -> host_cpu_load_info {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return info
    }

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    private func loadAverages() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let filled = getloadavg(&loads, 3)
        return filled > 0 ? Array(loads.prefix(Int(filled))) : []
    }
}
