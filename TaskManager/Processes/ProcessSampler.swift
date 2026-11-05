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

    /// Usage reported by `/bin/ps`, for processes we can't read directly.
    struct Fallback {
        /// Percent of one core (can exceed 100), a short decaying average.
        let cpuPercentOfOneCore: Double
        /// Resident memory in bytes.
        let residentBytes: UInt64
    }

    struct RawProcess {
        let pid: pid_t
        let parentPID: pid_t
        let uid: uid_t
        let command: String
        let path: String?
        let usage: Usage?
        /// The process macOS holds responsible for this one (e.g. Safari for its web content processes).
        let responsiblePID: pid_t?
        let fallback: Fallback?
    }

    /// One pass over every process. `ticksToNanos` converts rusage CPU times,
    /// which are Mach ticks (not nanoseconds) on Apple silicon.
    static func snapshot(ticksToNanos: Double) -> [RawProcess] {
        let fallbacks = psUsage() ?? [:]
        return allPIDs().compactMap { (pid: pid_t) -> RawProcess? in
            guard let info = bsdInfo(pid) else { return nil }
            let usage = resourceUsage(pid).map { ri in
                Usage(
                    cpuNanos: Double(ri.ri_user_time &+ ri.ri_system_time) * ticksToNanos,
                    diskBytes: ri.ri_diskio_bytesread &+ ri.ri_diskio_byteswritten,
                    memory: ri.ri_phys_footprint,
                    startTime: ri.ri_proc_start_abstime
                )
            }
            return RawProcess(
                pid: pid,
                parentPID: info.parentPID,
                uid: info.uid,
                command: info.command,
                path: path(pid),
                usage: usage,
                // Only needed for grouping our own processes under their app.
                responsiblePID: usage == nil ? nil : responsiblePID(pid),
                fallback: usage == nil ? fallbacks[pid] : nil
            )
        }
    }

    /// `/bin/ps` is setuid root on macOS, so it can read CPU and memory for
    /// system processes that a normal app can't. Returns nil if it can't.
    static func psUsage() -> [pid_t: Fallback]? {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,%cpu=,rss="], environment: ["LC_ALL": "C"])
        guard result.status == 0 else { return nil }

        var usage: [pid_t: Fallback] = [:]
        for line in result.output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3,
                  let pid = pid_t(columns[0]),
                  let cpu = Double(columns[1]),
                  let residentKB = UInt64(columns[2]) else { continue }
            usage[pid] = Fallback(cpuPercentOfOneCore: cpu, residentBytes: residentKB * 1024)
        }
        // If ps couldn't read root processes either, launchd (PID 1) shows 0 memory:
        // report "unknown" rather than misleading zeros.
        guard let launchd = usage[1], launchd.residentBytes > 0 else { return nil }
        return usage
    }

    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is a private libSystem function
    /// (the same "responsible process" macOS uses for privacy prompts). Looked up at
    /// runtime so the app still works, with less precise grouping, if it ever disappears.
    private static let responsibleForPID: ResponsibleForPID? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleForPID.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let function = responsibleForPID else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
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
