import Darwin
import Foundation

/// Thin wrappers around libproc. None of these need root, but `resourceUsage(_:)`
/// only succeeds for processes owned by the current user.
/// Everything here is safe to call off the main thread.
enum ProcessSampler {
    struct BSDInfo {
        let parentPID: pid_t
        let uid: uid_t
        let command: String
    }

    struct Usage {
        /// Total CPU time in nanoseconds.
        let cpuNanos: Double
        let diskBytes: UInt64
        let memory: UInt64
        /// Mach start time. PID + start time identifies one exact process.
        let startTime: UInt64
    }

    struct RawProcess {
        let pid: pid_t
        let uid: uid_t
        let command: String
        let path: String?
        let usage: Usage?
    }

    /// One pass over every process. `ticksToNanos` converts rusage CPU times,
    /// which are Mach ticks (not nanoseconds) on Apple silicon.
    static func snapshot(ticksToNanos: Double) -> [RawProcess] {
        allPIDs().compactMap { (pid: pid_t) -> RawProcess? in
            guard let info = bsdInfo(pid) else { return nil }
            let usage = resourceUsage(pid).map { ri in
                Usage(
                    cpuNanos: Double(ri.ri_user_time &+ ri.ri_system_time) * ticksToNanos,
                    diskBytes: ri.ri_diskio_bytesread &+ ri.ri_diskio_byteswritten,
                    memory: ri.ri_phys_footprint,
                    startTime: ri.ri_proc_start_abstime
                )
            }
            return RawProcess(pid: pid, uid: info.uid, command: info.command, path: path(pid), usage: usage)
        }
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    /// Works for every process, including root-owned ones.
    static func bsdInfo(_ pid: pid_t) -> BSDInfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return BSDInfo(
            parentPID: pid_t(truncatingIfNeeded: info.pbsi_ppid),
            uid: info.pbsi_uid,
            command: cString(info.pbsi_comm)
        )
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// CPU time, memory footprint, disk I/O and start time. Nil for other users' processes.
    static func resourceUsage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    /// Converts a fixed-size C char array (imported as a tuple) to a String.
    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
