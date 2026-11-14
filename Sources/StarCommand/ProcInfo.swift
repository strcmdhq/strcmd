import Darwin
import Foundation

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

enum ProcInfo {
    struct Identity: Hashable, Sendable {
        let uid: uid_t
        let parentPID: Int32
        let startTime: Date?
    }

    static func identity(pid: Int32) -> Identity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }
        return Identity(uid: proc.kp_eproc.e_ucred.cr_uid, parentPID: proc.kp_eproc.e_ppid, startTime: ProcessSampler.startTime(proc))
    }

    static func ancestors(of pid: Int32) -> Set<Int32> {
        var found: Set<Int32> = []
        var current = identity(pid: pid)?.parentPID ?? 0
        while current > 0, found.insert(current).inserted {
            current = identity(pid: current)?.parentPID ?? 0
        }
        return found
    }

    static func arguments(pid: Int32) -> (path: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcArgs.parse(Array(buffer.prefix(size)))
    }

    static func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? SwapUsage(usage) : nil
    }
}
